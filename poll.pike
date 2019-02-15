//Can be invoked from the command line for tools or interactive API inspection.

//NOTE: The saved stream and channel info are exactly as given by Twitch. Notably,
//all text strings are encoded UTF-8, and must be decoded before use.

void data_available(object q, function cbdata) {cbdata(q->unicode_data());}
void request_ok(object q, function cbdata) {q->async_fetch(data_available, cbdata);}
void request_fail(object q) { } //If a poll request fails, just ignore it and let the next poll pick it up.
void make_request(string url, function cbdata, int|void which_api) //which_api: 0=v3, 1=v5, 2=Helix
{
	sscanf(persist_config["ircsettings"]["pass"] || "", "oauth:%s", string pass);
	mapping headers = ([]);
	if (which_api == 1) headers["Accept"] = "application/vnd.twitchtv.v5+json";
	if (pass) headers["Authorization"] = "OAuth " + pass;
	//TODO: Use bearer auth where appropriate (is it exclusively when which_api==2?)
	if (string c=persist_config["ircsettings"]["clientid"])
		//Some requests require a Client ID. Not sure which or why.
		headers["Client-ID"] = c;
	Protocols.HTTP.do_async_method("GET", url, 0, headers,
		Protocols.HTTP.Query()->set_callbacks(request_ok,request_fail,cbdata));
}

class get_channel_info(string name, function callback)
{
	array cbargs;
	void create(mixed ... cbargs)
	{
		this->cbargs = cbargs;
		make_request("https://api.twitch.tv/kraken/channels/"+name, got_data);
	}

	void got_data(string data)
	{
		mapping info = Standards.JSON.decode(data);
		if (info->status == 404) {if (callback) callback(0, @cbargs); return;} //Probably a dud channel name
		//sscanf(info->_links->self, "https://api.twitch.tv/kraken/channels/%s", string gotname);
		//if (gotname != name) assert_fail;
		if (!G->G->channel_info[name]) G->G->channel_info[name] = info;
		if (callback) callback(info, @cbargs);
		/* Things we make use of:
		 * game => category
		 * mature => boolean, true if has click-through warning
		 * display_name => preferred way to show the channel name
		 * url => just "https://www.twitch.tv/"+name if we want to hack it
		 * status => stream title
		 * _id => numeric user ID
		 */
	}
}

class get_video_info(string name, function callback)
{
	array cbargs;
	void create(mixed ... cbargs)
	{
		this->cbargs = cbargs;
		make_request("https://api.twitch.tv/kraken/channels/" + name + "/videos?broadcast_type=archive&limit=1", got_data);
	}

	void got_data(string data)
	{
		mapping info = Standards.JSON.decode(data);
		if (info->status == 404 || !sizeof(info->videos)) info = 0; //Probably a dud channel name
		else info = info->videos[0];
		if (callback) callback(info, @cbargs);
	}
}

void streaminfo(string data)
{
	mapping info; catch {info = Standards.JSON.decode(data);}; //Some error returns aren't even JSON
	if (!info || info->error) return; //Ignore the 503s and stuff that come back.
	//First, quickly remap the array into a lookup mapping
	//This helps us ensure that we look up those we care about, and no others.
	mapping channels = ([]);
	foreach (info->data, mapping chan) channels[lower_case(chan->user_name)] = chan; //TODO: Figure out if user_name is login or display name
	//Now we check over our own list of channels. Anything absent is assumed offline.
	foreach (indices(persist_config["channels"]), string chan)
		stream_status(chan, channels[chan]);
}

int fetching_game_names = 0;
void gamenames(string data)
{
	mapping info; catch {info = Standards.JSON.decode(data);}; //Some error returns aren't even JSON
	if (!info || info->error) return; //Ignore the 503s and stuff that come back.
	foreach (info->data, mapping game) G->G->category_names[game->id] = game->name;
	write("Fetched %d games, total %d\n", sizeof(info->data), sizeof(G->G->category_names));
	if (!info->pagination || !info->pagination->cursor) {fetching_game_names = 0; write("-- Done!\n");}
	else call_out(cache_game_names, 2, info->pagination->cursor);
}
void cache_game_names(string pag) {make_request("https://api.twitch.tv/helix/games/top?first=100&after=" + pag, gamenames);}

//Attempt to construct a channel info mapping from the stream info
//May use other caches of information. If unable to build the full
//channel info, returns 0 (recommendation: fetch info via Kraken).
mapping build_channel_info(mapping stream)
{
	mapping ret = ([]);
	ret->game_id = stream->game_id;
	if (!(ret->game = G->G->category_names[stream->game_id]))
	{
		if (!fetching_game_names)
		{
			G->G->category_names = ([]);
			fetching_game_names = 1;
			cache_game_names("");
		}
		return 0;
	}
	//TODO: ret->mature, if possible
	ret->display_name = stream->user_name;
	ret->url = "https://www.twitch.tv/" + lower_case(stream->user_name); //TODO: Get the actual login, which may be different
	ret->status = stream->title;
	ret->_id = ret->user_id = stream->user_id;
	ret->_raw = stream; //Avoid using this except for testing
	//Add anything else here that might be of interest
	return ret;
}

//Receive stream status, either polled or by notification
void stream_status(string name, mapping info)
{
	if (!info)
	{
		if (!G->G->channel_info[name])
		{
			//Make sure we know about all channels
			write("** Channel %s isn't online - fetching last-known state **\n", name);
			get_channel_info(name, 0);
		}
		if (m_delete(G->G->stream_online_since, name))
		{
			write("** Channel %s noticed offline at %s **\n", name, Calendar.now()->format_nice());
			if (object chan = G->G->irc->channels["#"+name])
				chan->save(); //We don't get the offline time, so we'll pretend it was online right up until the time we noticed.
			runhooks("channel-offline", 0, name);
			mapping vstat = m_delete(G->G->viewer_stats, name);
			if (sizeof(vstat->half_hour) == 30)
			{
				mapping status = persist_status["stream_stats"];
				if (!status)
				{
					//Migrate from old persist
					status = ([]);
					foreach (persist_config["channels"]; string name; mapping chan)
					{
						array stats = m_delete(chan, "stream_stats");
						if (stats) status[name] = stats;
					}
					persist_status["stream_stats"] = status;
					persist_config->save();
				}
				status[name] += ({([
					"start": vstat->start, "end": time(),
					"viewers_high": vstat->high_half_hour,
					"viewers_low": vstat->low_half_hour,
				])});
				persist_status->save();
			}
		}
	}
	else
	{
		//Attempt to gather channel info from the stream info. If we
		//can't, we'll get that info via Kraken.
		string last_title = G->G->channel_info[name]?->status; //hack
		mapping synthesized = build_channel_info(info);
		if (synthesized) G->G->channel_info[name] = synthesized;
		else get_channel_info(name, 0);
		if (synthesized?->status != last_title) write("Old title: %O\nNew title: %O\n", last_title, synthesized?->status); //hack
		//TODO: Report when the game changes?
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->started_at);
		if (!G->G->stream_online_since[name])
		{
			//Is there a cleaner way to say "convert to local time"?
			object started_here = started->set_timezone(Calendar.now()->timezone());
			write("** Channel %s went online at %s **\n", name, started_here->format_nice());
			if (object chan = G->G->irc->channels["#"+name])
				chan->save(started->unix_time());
			runhooks("channel-online", 0, name);
		}
		G->G->stream_online_since[name] = started;
		int viewers = info->viewer_count;
		//Calculate half-hour rolling average, and then do stats on that
		//Record each stream's highest and lowest half-hour average, and maybe the overall average (not the average of the averages)
		//To maybe do: Offer a graph showing the channel's progress. Probably now done better by
		//StreamLabs, but we could have our own graph to double-check and maybe learn about
		//different measuring/reporting techniques.
		mapping vstat = G->G->viewer_stats; if (!vstat) vstat = G->G->viewer_stats = ([]);
		if (!vstat[name]) vstat[name] = (["start": time()]); //The stats might not have started at stream start, eg if bot wasn't running
		vstat = vstat[name]; //Focus on this channel.
		vstat->half_hour += ({viewers});
		if (sizeof(vstat->half_hour) >= 30)
		{
			vstat->half_hour = vstat->half_hour[<29..]; //Keep just the last half hour of stats
			int avg = `+(@vstat->half_hour) / 30;
			vstat->high_half_hour = max(vstat->high_half_hour, avg);
			if (!has_index(vstat, "low_half_hour")) vstat->low_half_hour = avg;
			else vstat->low_half_hour = min(vstat->low_half_hour, avg);
		}
	}
}

class check_following(string user, string chan, function|void callback)
{
	array cbargs;
	void create(mixed ... cbargs)
	{
		this->cbargs = cbargs;
		//CJA 20161006: Am now sending auth, but it's the default auth. Might
		//need to get a stronger auth than chat_login, which would mean properly
		//talking to the API and setting everything up.
		//https://github.com/justintv/Twitch-API/blob/master/authentication.md
		make_request("https://api.twitch.tv/kraken/users/" + user + "/follows/channels/" + chan, got_data);
	}

	void got_data(string data)
	{
		mapping info; catch {info = Standards.JSON.decode(data);}; //As above
		if (!info) return; //Server failure, probably
		if (info->status == 404)
		{
			//Not following. Explicitly store that info.
			sscanf(info->message, "%s is not following %s", string user, string chan);
			if (!chan) return;
			mapping foll = G_G_("participants", chan, user);
			foll->following = 0;
			if (callback) callback(user, chan, foll, @cbargs);
		}
		if (info->error) return; //Unknown error. Ignore it (most likely the user will be assumed not to be a follower).
		sscanf(info->_links->self, "https://api.twitch.tv/kraken/users/%s/follows/channels/%s", string user, string chan);
		mapping foll = G_G_("participants", chan, user);
		foll->following = "since " + info->created_at;
		if (callback) callback(user, chan, foll, @cbargs);
	}
}

void confirm_webhook() {/* There's no data or anything, so nothing to do */}

void webhooks(string resp)
{
	//TODO: Paginate properly. If we have more than 100 webhooks, some will be lost.
	mixed data = Standards.JSON.decode_utf8(resp); if (!mappingp(data)) return;
	multiset(string) follows = (<>);
	foreach (data->data, mapping hook)
	{
		int time_left = Calendar.ISO.parse("%Y-%M-%DT%h:%m:%s%z", hook->expires_at)->unix_time() - time();
		if (time_left < 300) continue;
		sscanf(hook->callback, "http%*[s]://%*s/junket?%s=%s", string type, string channel);
		if (!G->G->webhook_signer[channel]) continue; //Probably means the bot's been restarted
		if (type == "follow") follows[channel] = 1;
	}
	//write("Already got webhooks for %s\n", indices(watching) * ", ");
	if (!G->G->webhook_signer) G->G->webhook_signer = ([]);
	foreach (persist_config["channels"] || ([]); string chan; mapping cfg)
	{
		if (follows[chan]) continue; //Already got a hook
		if (!cfg->allcmds) continue; //Show only for channels we're fully active in
		mapping c = G->G->channel_info[chan];
		int userid = c && c->_id; //For some reason, ?-> is misparsing the data type (???)
		if (!userid) continue; //We need the user ID for this. If we don't have it, the hook can be retried later. (This also suppresses !whisper.)
		string secret = MIME.encode_base64(random_string(15));
		G->G->webhook_signer[chan] = Crypto.SHA256.HMAC(secret);
		write("Creating webhook for %s\n", chan);
		Protocols.HTTP.do_async_method("POST", "https://api.twitch.tv/helix/webhooks/hub", 0,
			([
				"Content-Type": "application/json",
				"Client-Id": persist_config["ircsettings"]["clientid"],
			]),
			Protocols.HTTP.Query()->set_callbacks(request_ok, request_fail, confirm_webhook),
			string_to_utf8(Standards.JSON.encode(([
				"hub.callback": sprintf("%s/junket?follow=%s",
					persist_config["ircsettings"]["http_address"],
					chan,
				),
				"hub.mode": "subscribe",
				"hub.topic": "https://api.twitch.tv/helix/users/follows?first=1&to_id=" + userid,
				"hub.lease_seconds": 864000,
				"hub.secret": secret,
			]))),
		);
	}
}

void check_webhooks()
{
	if (!G->G->webhook_lookup_token) return;
	Protocols.HTTP.do_async_method("GET", "https://api.twitch.tv/helix/webhooks/subscriptions?first=100", 0, ([
		"Authorization": "Bearer " + G->G->webhook_lookup_token,
	]), Protocols.HTTP.Query()->set_callbacks(request_ok, request_fail, webhooks));
}

void got_lookup_token(string resp)
{
	mixed data = Standards.JSON.decode_utf8(resp); if (!mappingp(data)) return;
	G->G->webhook_lookup_token = data->access_token;
	G->G->webhook_lookup_token_expiry = time() + data->expires_in - 120;
	check_webhooks();
}

void get_lookup_token()
{
	if (!persist_config["ircsettings"]["clientsecret"]) return;
	m_delete(G->G, "webhook_lookup_token");
	G->G->webhook_lookup_token_expiry = time() + 1; //Prevent spinning
	Protocols.HTTP.do_async_method("POST", "https://id.twitch.tv/oauth2/token", ([
		"client_id": persist_config["ircsettings"]["clientid"],
		"client_secret": persist_config["ircsettings"]["clientsecret"],
		"grant_type": "client_credentials",
	]), 0, Protocols.HTTP.Query()->set_callbacks(request_ok, request_fail, got_lookup_token));
}

void poll()
{
	G->G->poll_call_out = call_out(poll, 60); //TODO: Make the poll interval customizable
	array chan = indices(persist_config["channels"] || ({ }));
	if (!sizeof(chan)) return; //Nothing to check.
	//Note: There's a slight TOCTOU here - the list of channel names will be
	//re-checked from persist_config when the response comes in. If there are
	//channels that we get info for and don't need, ignore them; if there are
	//some that we wanted but didn't get, we'll just think they're offline
	//until the next poll.
	make_request(sprintf("https://api.twitch.tv/helix/streams?%{user_login=%s&%}", chan), streaminfo);
	string addr = persist_config["ircsettings"]["http_address"];
	if (addr && addr != "")
	{
		if (G->G->webhook_lookup_token_expiry < time()) get_lookup_token();
		else check_webhooks();
	}
}

void create()
{
	if (!G->G->stream_online_since) G->G->stream_online_since = ([]);
	if (!G->G->channel_info) G->G->channel_info = ([]);
	if (!G->G->category_names) G->G->category_names = ([]);
	remove_call_out(G->G->poll_call_out);
	poll();
	add_constant("get_channel_info", get_channel_info);
	add_constant("check_following", check_following);
	add_constant("get_video_info", get_video_info);
}

#if !constant(G)
mapping G = (["G":([])]);
mapping persist_config = (["channels": ({ }), "ircsettings": Standards.JSON.decode_utf8(Stdio.read_file("twitchbot_config.json"))["ircsettings"] || ([])]);
mapping persist_status = ([]);
void runhooks(mixed ... args) { }
mapping G_G_(mixed ... args) {return ([]);}

int requests;

mapping decode(string data)
{
	mapping info = Standards.JSON.decode(data);
	if (info && !info->error) return info;
	if (!info) write("Request failed - server down?\n");
	else write("%d %s: %s\n", info->status, info->error, info->message||"(unknown)");
	if (!--requests) exit(0);
}

void interactive(string data)
{
	mapping info = decode(data); if (!info) return;
	write("%O\n", info);
	//TODO: Surely there's a better way to access the history object for the running Hilfe...
	object history = function_object(all_constants()["backend_thread"]->backtrace()[0]->args[0])->history;
	history->push(info);
}
int req(string url, int|void v5) //Returns 0 to suppress Hilfe warning.
{
	if (!has_prefix(url, "http")) url = "https://api.twitch.tv/kraken/" + url[url[0]=='/'..];
	make_request(url, interactive, v5);
}

//Lifted from globals because I can't be bothered refactoring
string describe_time_short(int tm)
{
	string msg = "";
	int secs = tm;
	if (int t = secs/86400) {msg += sprintf("%d, ", t); secs %= 86400;}
	if (tm >= 3600) msg += sprintf("%02d:%02d:%02d", secs/3600, (secs%3600)/60, secs%60);
	else if (tm >= 60) msg += sprintf("%02d:%02d", secs/60, secs%60);
	else msg += sprintf("%02d", tm);
	return msg;
}

void streaminfo_display(string data)
{
	mapping info = decode(data); if (!info) return;
	sscanf(info->_links->self, "https://api.twitch.tv/kraken/streams/%s", string name);
	if (info->stream)
	{
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->stream->created_at);
		write("Channel %s went online at %s\n", name, started->format_nice());
		write("Uptime: %s\n", describe_time_short(started->distance(Calendar.now())->how_many(Calendar.Second())));
	}
	else write("Channel %s is offline.\n", name);
	if (!--requests) exit(0);
}
void chaninfo_display(string data)
{
	mapping info = decode(data); if (!info) return;
	sscanf(info->_links->self, "https://api.twitch.tv/kraken/channels/%s", string name);
	if (info->mature) write("[MATURE] ");
	write("%s was last seen playing %s, at %s - %s\n",
		info->display_name, info->game || "(null)", info->url, string_to_utf8(info->status || "(null)"));
	if (!--requests) exit(0);
}
void followinfo_display(string user, string chan, mapping info)
{
	if (!info->following) write("%s is not following %s.\n", user, chan);
	else write("%s has been following %s %s.\n", user, chan, (info->following/"T")[0]);
	if (!--requests) exit(0);
}

void transcoding_display(string data)
{
	mapping info = Standards.JSON.decode(data);
	if (info->status == 404 || !sizeof(info->videos))
	{
		write("Error fetching transcoding info: %O\n", info);
		if (!--requests) exit(0);
		return;
	}
	foreach (info->videos, mapping videoinfo)
	{
		mapping res = videoinfo->resolutions;
		if (!res || !sizeof(res)) return; //Shouldn't happen
		string dflt = m_delete(res, "chunked") || "?? unknown res ??"; //Not sure if "chunked" can ever be missing
		write("[%s] %-9s %s - %s\n", videoinfo->created_at, dflt, sizeof(res) ? "TC" : "  ", videoinfo->game);
	}
	if (!--requests) exit(0);
}

mapping gamecounts = ([]), gameviewers = ([]), gamechannel = ([]);
void show_turkish(string data)
{
	mapping info = decode(data); if (!info) exit(0);
	foreach (info->streams, mapping st)
	{
		gamecounts[st->channel->game]++;
		gameviewers[st->channel->game] += st->viewers;
		gamechannel[st->channel->game] = st->channel->display_name + ": " + st->channel->status;
	}
	if (sizeof(info->streams) == 100) {make_request(info->_links->next, show_turkish); return;}
	//Print out a summary
	if (sizeof(gamecounts))
	{
		array games = ({ });
		foreach (gamecounts; string game; int count)
			if (count > 1) games += ({sprintf("%3d:%3d %s", count, gameviewers[game], game)});
			else games += ({sprintf("  1:%3d %s - %s", gameviewers[game], game, gamechannel[game])});
		sort(games);
		write("%{%s\n%}", string_to_utf8(reverse(games)[*]));
	}
	else write("No games online.\n");
	exit(0);
}

int n = 0;
void find_s0lar(string data)
{
	mapping info = decode(data); if (!info) exit(0);
	n += sizeof(info->follows);
	foreach (info->follows, mapping f)
		if (has_value(f->user->name + f->user->display_name, "s0lar"))
			write("%s created %s followed %s\n", f->user->display_name, f->user->created_at, f->created_at);
	if (!info->_links->next) {werror("Checked %d followers\n", n); exit(0);} //Not working - it's not stopping. Weird.
	werror("%d...\r", n);
	make_request(info->_links->next, find_s0lar);
}

int main(int argc, array(string) argv)
{
	if (argc == 1)
	{
		Tools.Hilfe.StdinHilfe(({"inherit \"poll.pike\";", "start backend"}));
		return 0;
	}
	if (argc > 1 && argv[1] == "hack")
	{
		//TODO: Have a generic way to do this nicely.
		//make_request("https://api.twitch.tv/kraken/streams?language=tr&limit=100&stream_type=live", show_turkish);
		make_request("https://api.twitch.tv/kraken/channels/devicat/follows?limit=100", find_s0lar);
		return -1;
	}
	requests = argc - 1;
	foreach (argv[1..], string chan)
	{
		if (sscanf(chan, "%s/%s", string ch, string user) && user)
		{
			if (user == "transcoding")
			{
				write("Checking transcoding history...\n");
				make_request("https://api.twitch.tv/kraken/channels/" + ch + "/videos?broadcast_type=archive&limit=100", transcoding_display);
				continue;
			}
			write("Checking follow status...\n");
			check_following(user, ch, followinfo_display);
		}
		else
		{
			//For online channels, we could save ourselves one request. Simpler to just do 'em all though.
			++requests; //These require two requests
			make_request("https://api.twitch.tv/kraken/streams/"+chan, streaminfo_display);
			make_request("https://api.twitch.tv/kraken/channels/"+chan, chaninfo_display);
		}
	}
	return requests && -1;
}
#endif
