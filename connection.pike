object irc;
string bot_nick;

class IRCClient
{
	inherit Protocols.IRC.Client;
	#if __REAL_VERSION__ < 8.1
	//Basically monkey-patch in a couple of methods that Pike 8.0 doesn't ship with.
	void join_channel(string chan)
	{
	   cmd->join(chan);
	   if (options->channel_program)
	   {
	      object ch = options->channel_program();
	      ch->name = lower_case(chan);
	      channels[lower_case(chan)] = ch;
	   }
	}

	void part_channel(string chan)
	{
	   cmd->part(chan);
	   m_delete(channels, lower_case(chan));
	}
	#endif

	void got_command(string what, string ... args)
	{
		//With the capability "twitch.tv/tags" active, some messages get delivered prefixed.
		//The Pike IRC client doesn't handle the prefixes, and I'm not sure how standardized
		//this concept is (it could be completely Twitch-exclusive), so I'm handling it here.
		//The prefix is formatted as "@x=y;a=b;q=w" with simple key=value pairs. We parse it
		//out into a mapping and pass that along to not_message. Note that we also parse out
		//whispers the same way, even though there's actually no such thing as whisper_notif
		//in the core Protocols.IRC.Client handler - they go through to not_message for some
		//channel (currently "#!whisper", though this may change in the future).
		mapping(string:string) attr = ([]);
		if (has_prefix(what, "@"))
		{
			foreach (what[1..]/";", string att)
			{
				[string name, string val] = att/"=";
				attr[replace(name, "-", "_")] = replace(val, "\\s", " ");
			}
			//write(">> %O %O <<\n", args[0], attr);
		}
		sscanf(args[0], "%s :%s", string a, string message);
		array parts = (a || args[0]) / " ";
		if (sizeof(parts) >= 3 && (<"PRIVMSG", "NOTICE", "WHISPER", "USERNOTICE">)[parts[1]])
		{
			//Send whispers to a pseudochannel named #!whisper
			string chan = parts[1] == "WHISPER" ? "#!whisper" : lower_case(parts[2]);
			if (object c = channels[chan])
			{
				attr->_type = parts[1]; //Distinguish the three types of message
				c->not_message(person(@(parts[0] / "!")), message, attr);
				return;
			}
		}
		::got_command(what, @args);
	}
}

void error_notify(mixed ... args) {werror("error_notify: %O\n", args);}

int mod_query_delay = 0;
void reconnect()
{
	//NOTE: This appears to be creating duplicate channel joinings, for some reason.
	//HACK: Destroy and reconnect - this might solve the above problem. CJA 20160401.
	if (irc && irc == G->G->irc) {irc->close(); if (objectp(irc)) destruct(irc); werror("%% Reconnecting\n");}
	//TODO: Dodge the synchronous gethostbyname?
	mapping opt = persist_config["ircsettings"];
	if (!opt) return; //Not yet configured - can't connect.
	opt += (["channel_program": channel_notif, "connection_lost": reconnect,
		"error_notify": error_notify]);
	mod_query_delay = 0; //Reset the delay
	if (mixed ex = catch {
		G->G->irc = irc = IRCClient("irc.chat.twitch.tv", opt);
		#if __REAL_VERSION__ >= 8.1
		function cap = irc->cmd->cap;
		#else
		//The 'cap' command isn't supported by Pike 8.0's Protocols.IRC.Client,
		//so we create our own, the same way. There will be noisy failures from
		//the responses, but it's fine in fire-and-forget mode.
		function cap = irc->cmd->SyncRequest(Protocols.IRC.Requests.NoReply("CAP", "string", "text"), irc->cmd);
		#endif
		cap("REQ","twitch.tv/membership");
		cap("REQ","twitch.tv/commands");
		cap("REQ","twitch.tv/tags");
		irc->join_channel(("#"+(indices(persist_config["channels"])-({"!whisper"}))[*])[*]);
		//Hack: Create a fake channel object for whispers
		//Rather than having a pseudo-channel, it would probably be better to
		//have a "primary channel" that handles all whispers - effectively,
		//whispered commands are treated as if they were sent to that channel,
		//except that the response is whispered.
		if (persist_config["channels"]["!whisper"])
		{
			object ch = channel_notif();
			ch->name = "#!whisper";
			irc->channels["#!whisper"] = ch;
		}
	})
	{
		//Something went wrong with the connection. Most likely, it's a
		//network issue, so just print the exception and retry in a
		//minute (non-backoff).
		werror("%% Error connecting to Twitch:\n%s\n", describe_error(ex));
		//Since other modules will want to look up G->G->irc->channels,
		//let them. One little shim is all it takes.
		G->G->irc = (["close": lambda() { }, "channels": ([])]);
	}
}

//NOTE: When this file gets updated, the queue will not be migrated.
//The old queue will be pumped by the old code, and the new code will
//have a new (empty) queue.
int lastmsgtime = time();
int modmsgs = 0;
array msgqueue = ({ });
void pump_queue()
{
	int tm = time(1);
	if (tm == lastmsgtime) {call_out(pump_queue, 1); return;}
	lastmsgtime = tm; modmsgs = 0;
	[[string|array to, string msg], msgqueue] = Array.shift(msgqueue);
	irc->send_message(to, string_to_utf8(msg));
}
void send_message(string|array to, string msg, int|void is_mod)
{
	if (stringp(to) && has_prefix(to, "/"))
	{
		msg = to + " " + msg; //eg "/w target message"
		to = "#" + bot_nick; //Shouldn't matter what the dest is with these.
	}
	int tm = time(1);
	if (is_mod)
	{
		//Mods can always ignore slow-mode. But they should still keep it to
		//a max of 100 messages in 30 seconds (which I simplify down to 3/sec)
		//to avoid getting globalled.
		if (tm != lastmsgtime) {lastmsgtime = tm; modmsgs = 0;}
		if (++modmsgs < 3)
		{
			irc->send_message(to, string_to_utf8(msg));
			return;
		}
	}
	if (sizeof(msgqueue) || tm == lastmsgtime)
	{
		msgqueue += ({({to, msg})});
		call_out(pump_queue, 1);
	}
	else
	{
		lastmsgtime = tm; modmsgs = 0;
		irc->send_message(to, string_to_utf8(msg));
	}
}

constant badge_aliases = ([ //Fold a few badges together, and give shorthands for others
	"broadcaster": "_mod", "moderator": "_mod", "staff": "_mod", //TODO: Also add global mods
	//"subscriber": "_sub", //if you want shorthand
]);
//Go through a message's parameters/tags to get the info about the person
mapping(string:mixed) gather_person_info(object person, mapping params)
{
	mapping ret = (["nick": person->nick, "user": person->user]);
	if (params->user_id) ret->uid = (int)params->user_id;
	ret->displayname = params->display_name || person->nick;
	if (params->badges)
	{
		ret->badges = ([]);
		foreach (params->badges / ",", string badge) if (badge != "")
		{
			sscanf(badge, "%s/%d", badge, int status);
			ret->badges[badge] = status;
			if (string flag = badge_aliases[badge]) ret->badges[flag] = status;
		}
	}
	return ret;
}

class channel_notif
{
	inherit Protocols.IRC.Channel;
	string color;
	mapping config = ([]);
	multiset mods=(<>);
	mapping(string:int) viewers = ([]);
	mapping(string:array(int)) viewertime; //({while online, while offline})
	mapping(string:array(int)) wealth; //({actual currency, fractional currency})
	mixed save_call_out;
	string hosting;

	void create() {call_out(configure,0);}
	void configure() //Needs to happen after this->name is injected by Protocols.IRC.Client
	{
		config = persist_config["channels"][name[1..]];
		if (config->chatlog)
		{
			if (!G->G->channelcolor[name]) {if (++G->G->nextcolor>7) G->G->nextcolor=1; G->G->channelcolor[name]=G->G->nextcolor;}
			color = sprintf("\e[1;3%dm", G->G->channelcolor[name]);
		}
		else color = "\e[0m"; //Nothing will normally be logged, so don't allocate a color. If logging gets enabled, it'll take a reset to assign one.
		if (config->currency && config->currency!="") wealth = persist_status->path("wealth", name);
		if (config->countactive || wealth) //Note that having channel currency implies counting activity time.
		{
			viewertime = persist_status->path("viewertime", name);
			foreach (viewertime; string user; int|array val) if (intp(val)) m_delete(viewertime, user);
		}
		else if (persist_status["viewertime"]) m_delete(persist_status["viewertime"], name);
		persist_status->save();
		save_call_out = call_out(save, 300);
		//Twitch will (eventually) notify us of who has "ops" privilege, which
		//corresponds to mods and other people with equivalent powers. But on
		//startup, it's quicker to (a) grant mod powers to the streamer, and
		//(b) ask Twitch who the other mods are. This won't catch people with
		//special powers (Twitch staff etc), so they may not be able to run
		//mod-only commands until the "MODE" lines come through.
		mods[name[1..]] = 1;
		//For some reason, this one line of code triggers the reconnect loop
		//bug. I have no idea what the actual cause is, but the issue seems
		//to be less common if the commands get spaced out a bit - delay the
		//first one by 1 second, the second by 2, etc.
		//call_out(irc->send_message, ++mod_query_delay, name, "/mods");
		//20181221: Instead of asking about all mods, we instead wait for one
		//of two events - either the MODE lines, or the person speaking in
		//chat, with the mod badge or equivalent.
	}

	void destroy() {save(); remove_call_out(save_call_out);}
	void _destruct() {save(); remove_call_out(save_call_out);}
	void save(int|void as_at)
	{
		//Save everyone's online time on code reload and periodically
		remove_call_out(save_call_out); save_call_out = call_out(save, 300);
		if (!as_at) as_at = time();
		int count = 0;
		int offline = !G->G->stream_online_since[name[1..]];
		int payout_div = wealth && (offline ? config->payout_offline : 1);
		foreach (viewers; string user; int start) if (start && as_at > start)
		{
			int t = as_at-start;
			if (viewertime)
			{
				if (!viewertime[user]) viewertime[user] = ({0,0});
				viewertime[user][offline] += t;
			}
			viewers[user] = as_at;
			if (payout_div)
			{
				if (!wealth[user]) wealth[user] = ({0, 0});
				if (int mul = mods[user] && config->payout_mod) t *= mul;
				t /= payout_div; //If offline payout is 1:3, divide the time spent by 3 and discard the loose seconds.
				t += wealth[user][1];
				wealth[user][0] += t / config->payout;
				wealth[user][1] = t % config->payout;
			}
			++count;
		}
		//write("[Saved %d viewer times for channel %s]\n", count, name);
		persist_status->save();
	}
	//NOTE: Without not_join and its friends, Pike 8.0 will spam noisy failure
	//messages. Everything seems to still work, though.
	void not_join(object who) {log("%sJoin %s: %s\e[0m\n",color,name,who->user); viewers[who->user] = time(1);}
	void not_part(object who,string message,object executor)
	{
		save(); //TODO, maybe: Save just this viewer's data
		m_delete(viewers, who->user);
		log("%sPart %s: %s\e[0m\n", color, name, who->user);
	}

	array(command_handler|string) locate_command(object person, string msg)
	{
		int mod = mods[person->user];
		if (command_handler f = sscanf(msg, "!%[^# ] %s", string cmd, string param)
			&& find_command(this, cmd, mod))
				return ({f, param||""});
		if (string cur = config->currency!="" && config->currency)
		{
			//Note that !currency will work (cf the above code), but !<currency-name> is the recommended way.
			if (msg == "!"+cur) return ({G->G->commands->currency, ""});
			if (sscanf(msg, "!"+cur+" %s", string param) == 1) return ({G->G->commands->currency, param});
		}
		return ({0, 0});
	}

	echoable_message substitute_markers(string|mapping|array(string|mapping) msg, mapping(string:string) markers)
	{
		if (stringp(msg)) return replace(msg, markers);
		if (mappingp(msg)) return msg | (["message": replace(msg->message, markers)]);
		if (arrayp(msg)) return substitute_markers(msg[*], markers); //Yes, recursive. You shouldn't have arrays in arrays though.
		return msg;
	}

	echoable_message handle_command(object|mapping person, string msg)
	{
		if (config->noticechat && person->user && has_value(lower_case(msg), config->noticeme||""))
		{
			mapping user = G_G_("participants", name[1..], person->user);
			//Re-check every five minutes, max. We assume that people don't
			//generally unfollow, so just recheck those every day.
			if (config->followers && user->lastfollowcheck <= time() - (user->following ? 86400 : 300))
			{
				user->lastfollowcheck = time();
				check_following(person->user, name[1..]);
			}
			user->lastnotice = time();
		}
		[command_handler cmd, string param] = locate_command(person, msg);
		//Functions do not get %s handling. If they want it, they can do it themselves,
		//and if they don't want it, it would mess things up badly to do it here.
		if (functionp(cmd)) return cmd(this, person, param);
		return substitute_markers(cmd, (["%s": param]));
	}

	void wrap_message(object|mapping person, echoable_message info, string|void defaultdest)
	{
		if (!info) return;
		if (arrayp(info)) {wrap_message(person, info[*], defaultdest); return;}
		if (stringp(info)) info = (["message": info]);
		string msg = info->message, dest = info->dest || defaultdest || name;
		if (dest == "/w $$") dest = "/w " + person->user;
		string prefix = replace(info->prefix || "", "$$", person->user);
		msg = replace(msg, "$$", person->user);
		if (config->noticechat && has_value(msg, "$participant$"))
		{
			array users = ({ });
			int limit = time() - config->timeout;
			foreach (G_G_("participants", name[1..]); string name; mapping info)
				if (info->lastnotice >= limit && name != person->user) users += ({name});
			//If there are no other chat participants, pick the person speaking.
			string chosen = sizeof(users) ? random(users) : person->user;
			msg = replace(msg, "$participant$", chosen);
		}
		//VERY simplistic form of word wrap.
		while (sizeof(msg) > 400)
		{
			sscanf(msg, "%400s%s %s", string piece, string word, msg);
			send_message(dest, sprintf("%s%s%s ...", prefix, piece, word), mods[bot_nick]);
		}
		send_message(dest, prefix + msg, mods[bot_nick]);
	}

	void not_message(object ircperson, string msg, mapping(string:string)|void params)
	{
		//TODO: Figure out whether msg and params are bytes or text
		//"Now hosting" needs to be decoded UTF-8 currently - should it be in here
		//or up in the higher-level parser?
		if (!params) params = ([]);
		mapping(string:mixed) person = gather_person_info(ircperson, params);
		if (!params->_type && person->nick == "tmi.twitch.tv")
		{
			//HACK: If we don't have the actual type provided, guess based on
			//the person's nick and the text of the message. Note that this code
			//is undertested and may easily be buggy. The normal case is that we
			//WILL get the correct message IDs, thus guaranteeing reliability.
			params->_type = "NOTICE";
			foreach (([
				"Now hosting %*s.": "host_on",
				"Exited host mode.": "host_off",
				"%*s has gone offline. Exiting host mode.": "host_target_went_offline",
				"The moderators of this channel are: %*s": "room_mods",
			]); string match; string id)
				if (sscanf(msg, match)) params->msg_id = id;
		}
		string defaultdest;
		switch (params->_type)
		{
			case "NOTICE": case "USERNOTICE": switch (params->msg_id)
			{
				case "host_on": if (sscanf(msg, "Now hosting %s.", string h) && h)
				{
					if (G->G->stream_online_since[name[1..]])
					{
						//Hosting when you're live is a raid. (It might not use the
						//actual /raid command, but for our purposes, it counts.)
						//This has a number of good uses. Firstly, a streamer can
						//check this to see who hasn't been raided recently, and
						//spread the love around; and secondly, a viewer can see
						//which channel led to some other channel ("ohh, I met you
						//when X raided you last week"). Other uses may also be
						//possible. So it's in a flat file, easily greppable.
						Stdio.append_file("outgoing_raids.log", sprintf("[%s] %s => %s\n",
							Calendar.now()->format_time(), name[1..], h));
					}
					hosting = h;
				}
				break;
				case "host_off": case "host_target_went_offline": hosting = 0; break;
				case "room_mods": if (sscanf(msg, "The moderators of this channel are: %s", string names) && names)
				{
					//Response to a "/mods" command
					foreach (names / ", ", string name) if (!mods[name])
					{
						log("%sAcknowledging %s as a mod\e[0m\n", color, name);
						mods[name] = 1;
					}
				}
				break;
				case "slow_on": case "slow_off": break; //Channel is now/no longer in slow mode
				case "msg_duplicate": case "msg_slowmode": case "msg_timedout": case "msg_banned":
					/* Last message wasn't sent, for some reason. There seems to be no additional info in the tags.
					- Your message was not sent because it is identical to the previous one you sent, less than 30 seconds ago.
					- This room is in slow mode and you are sending messages too quickly. You will be able to talk again in %d seconds.
					- You are banned from talking in %*s for %d more seconds.
					All of these indicate that the most recent message wasn't sent. Is it worth trying to retrieve that message?
					*/
					break;
				case "raid": case "unraid": break; //Incoming raids already get announced and we don't get any more info
				case "sub": trigger_special("!sub", person, (["{tier}": params->msg_param_sub_plan[0]])); break;
				case "resub": trigger_special("!resub", person, ([
					"{tier}": params->msg_param_sub_plan[0],
					"{months}": params->msg_param_months,
				]));
				break;
				case "giftpaidupgrade": break; //Pledging to continue a subscription (first introduced for the Subtember special in 2018, and undocumented)
				case "subgift":
				{
					trigger_special("!subgift", person, ([
						"{tier}": params->msg_param_sub_plan[0],
						"{months}": params->msg_param_months,
						"{recipient}": params->msg_param_recipient_display_name,
					]));
					write("DEBUG SUBGIFT: chan %s disp %O user %O\n", name, person->displayname, person->user);
					//Other params: login, user_id, msg_param_recipient_user_name, msg_param_recipient_id,
					//msg_param_sender_count (the total gifts this person has given in this channel)
					//Remember that all params are strings, even those that look like numbers
					break;
				}
				case "submysterygift": trigger_special("!subbomb", person, ([
					"{tier}": params->msg_param_sub_plan[0],
					"{gifts}": params->msg_param_mass_gift_count,
				]));
				break;
				default: werror("Unrecognized %s with msg_id %O on channel %s\n%O\n%O\n",
					params->_type, params->msg_id, name, params, msg);
			}
			break;
			case "WHISPER": defaultdest = "/w $$"; //fallthrough
			case "PRIVMSG":
			{
				if (lower_case(person->nick) == lower_case(bot_nick)) {lastmsgtime = time(1); modmsgs = 0;}
				if (person->badges) mods[person->user] = person->badges->_mod;
				wrap_message(person, handle_command(person, msg), defaultdest);
				if (sscanf(msg, "\1ACTION %s\1", string slashme)) msg = person->displayname+" "+slashme;
				else msg = person->displayname+": "+msg;
				string pfx=sprintf("[%s] ", name);
				#ifdef __NT__
				int wid = 80 - sizeof(pfx);
				#else
				int wid = Stdio.stdin->tcgetattr()->columns - sizeof(pfx);
				#endif
				if (person->badges?->_mod) msg = string_to_utf8("\u2694 ") + msg;
				log("%s%s\e[0m", color, sprintf("%*s%-=*s\n",sizeof(pfx),pfx,wid,msg));
				if (params->bits && (int)params->bits)
					trigger_special("!cheer", person, (["{bits}": params->bits]));
				break;
			}
			default: werror("Unknown message type %O on channel %s\n", params->_type, name);
		}
	}
	void not_mode(object who,string mode)
	{
		if (sscanf(mode, "+o %s", string newmod)) mods[newmod] = 1;
		if (sscanf(mode, "-o %s", string outmod)) mods[outmod] = 1;
		log("%sMode %s: %s %O\e[0m\n",color,name,who->nick,mode);
	}

	void log(strict_sprintf_format fmt, sprintf_args ... args)
	{
		if (config->chatlog) write(fmt, @args);
	}

	void trigger_special(string special, mapping person, mapping info)
	{
		echoable_message response = G->G->echocommands[special + name];
		if (!response) return;
		wrap_message(person, substitute_markers(response, info));
	}
}

void http_handler(Protocols.HTTP.Server.Request req)
{
	if (string c = req->variables["hub.challenge"])
	{
		//It's a hook confirmation from Twitch
		werror("HTTP - hub.challenge %s\n", req->variables["hub.topic"] || "(??)");
		req->response_and_finish((["data": c]));
		return;
	}
	if (function handler = !has_prefix(req->not_query, "/chan_") &&
		G->G->http_endpoints[req->not_query[1..]])
	{
		if (mapping resp = handler(req)) {req->response_and_finish(resp); return;}
	}
	if (sscanf(req->not_query, "/channels/%[^/]%s", string chan, string no_endpoint) && no_endpoint == "")
	{
		//Hack: Redirect /channels/rosuav to /channels/rosuav/
		req->response_and_finish((["error": 301, "extra_heads": (["Location": sprintf("/channels/%s/", chan)])]));
		return;
	}
	if (function handler = sscanf(req->not_query, "/channels/%s/%s", string chan, string endpoint) &&
		G->G->http_endpoints["chan_" + endpoint])
	{
		object channel = G->G->irc->channels["#" + chan];
		if (!channel || !channel->config->allcmds)
		{
			//TODO: Better handle the quieter channels?
			req->response_and_finish(([
				"data": "No such page.\n",
				"type": "text/plain; charset=\"UTF-8\"",
				"error": 404,
			]));
			//Don't bother reporting these on the console. We know the endpoint is valid.
			return;
		}
		if (mapping resp = handler(req, channel)) {req->response_and_finish(resp); return;}
	}
	werror("HTTP request: %s %O %O\n", req->request_type, req->not_query, req->variables);
	werror("Headers: %O\n", req->request_headers);
	req->response_and_finish(([
		"data": "No such page.\n",
		"type": "text/plain; charset=\"UTF-8\"",
		"error": 404,
	]));
}

void create()
{
	if (!G->G->channelcolor) G->G->channelcolor = ([]);
	irc = G->G->irc;
	//if (!irc) //HACK: Force reconnection every time
		reconnect();
	if (mapping irc = persist_config["ircsettings"])
	{
		bot_nick = persist_config["ircsettings"]->nick || "";
		if (irc->http_address && irc->http_address != "")
		{
			int use_https = has_prefix(irc->http_address, "https://");
			string listen_addr = "::"; //By default, listen on IPv4 and IPv6
			int listen_port = use_https ? 443 : 80; //Default port from protocol
			sscanf(irc->http_address, "http%*[s]://%*s:%d", listen_port); //If one is set for the dest addr, use that
			//Or if there's an explicit listen address/port set, use that.
			sscanf(irc->listen_address||"", "%d", listen_port);
			sscanf(irc->listen_address||"", "%s:%d", listen_addr, listen_port);

			if (listen_port * -use_https != G->G->httpserver_port_used)
			{
				//Port or SSL status has changed. Force the server to be restarted.
				if (object http = m_delete(G->G, "httpserver")) http->close();
				G->G->httpserver_port_used = listen_port * -use_https;
			}

			if (G->G->httpserver) G->G->httpserver->callback = http_handler;
			else if (!use_https) G->G->httpserver = Protocols.HTTP.Server.Port(http_handler, listen_port, listen_addr);
			else
			{
				string cert = Stdio.read_file("certificate.pem"),
					key = Stdio.read_file("privkey.pem");
				array certs = cert && Standards.PEM.Messages(cert)->get_certificates();
				string pk = key && Standards.PEM.simple_decode(key);
				//If we don't have a valid PK and cert(s), Pike will autogenerate a cert.
				//TODO: Save the cert? That way, the self-signed could be pinned
				//permanently. Currently it'll be regenned each startup.
				G->G->httpserver = Protocols.HTTP.Server.SSLPort(http_handler, listen_port, listen_addr, pk, certs);
			}
		}
	}
	add_constant("send_message", send_message);
}
