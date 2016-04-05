object irc;

void reconnect()
{
	//NOTE: This appears to be creating duplicate channel joinings, for some reason.
	//HACK: Destroy and reconnect - this might solve the above problem. CJA 20160401.
	if (irc) {irc->close(); destruct(irc); werror("%% Reconnecting\n");}
	//TODO: Dodge the synchronous gethostbyname?
	G->G->irc = irc = Protocols.IRC.Client("irc.chat.twitch.tv", G->config);
	irc->cmd->cap("REQ","twitch.tv/membership");
	irc->join_channel(("#"+indices(persist["channels"])[*])[*]);
}

//NOTE: When this file gets updated, the queue will not be migrated.
//The old queue will be pumped by the old code, and the new code will
//have a new (empty) queue.
int lastmsgtime = time();
array msgqueue = ({ });
void pump_queue()
{
	int tm = time(1);
	if (tm == lastmsgtime) {call_out(pump_queue, 1); return;}
	lastmsgtime = tm;
	[[string|array to, string msg], msgqueue] = Array.shift(msgqueue);
	irc->send_message(to, msg);
}
void send_message(string|array to,string msg)
{
	int tm = time(1);
	if (sizeof(msgqueue) || tm == lastmsgtime)
	{
		msgqueue += ({({to, msg})});
		call_out(pump_queue, 1);
	}
	else
	{
		lastmsgtime = tm;
		irc->send_message(to, msg);
	}
}

class channel_notif
{
	inherit Protocols.IRC.Channel;
	string color;
	mapping config;
	multiset mods=(<>);
	mapping(string:int) viewers = ([]);
	mapping(string:array(int)) viewertime; //({while online, while offline})
	mapping(string:array(int)) wealth; //({actual currency, fractional currency})
	mixed save_call_out;

	void create() {call_out(configure,0);}
	void configure() //Needs to happen after this->name is injected by Protocols.IRC.Client
	{
		config = persist["channels"][name[1..]];
		if (config->chatlog)
		{
			if (!G->G->channelcolor[name]) {if (++G->G->nextcolor>7) G->G->nextcolor=1; G->G->channelcolor[name]=G->G->nextcolor;}
			color = sprintf("\e[1;3%dm", G->G->channelcolor[name]);
		}
		else color = "\e[0m"; //Nothing will normally be logged, so don't allocate a color. If logging gets enabled, it'll take a reset to assign one.
		viewertime = persist->path("viewertime", name);
		foreach (viewertime; string user; int|array val) if (intp(val)) m_delete(viewertime, user); persist->save();
		if (config->currency && config->currency!="") wealth = persist->path("wealth", name);
		save_call_out = call_out(save, 300);
	}

	void destroy() {save(); remove_call_out(save_call_out);}
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
			if (!viewertime[user]) viewertime[user] = ({0,0});
			viewertime[user][offline] += t;
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
		log("[Saved %d viewer times for channel %s]\n", count, name);
		persist->save();
	}
	void not_join(object who) {log("%sJoin %s: %s\e[0m\n",color,name,who->user); viewers[who->user] = time(1);}
	void not_part(object who,string message,object executor)
	{
		save(); //TODO, maybe: Save just this viewer's data
		m_delete(viewers, who->user);
		log("%sPart %s: %s\e[0m\n", color, name, who->user);
	}

	string handle_command(object person, string msg)
	{
		if (function f = has_prefix(msg,"!") && G->G->commands[msg[1..]]) return f(this, person, "");
		if (function f = (sscanf(msg, "!%s %s", string cmd, string param) == 2) && G->G->commands[cmd]) return f(this, person, param);
		if (string cur = config->currency!="" && config->currency)
		{
			//Note that !currency will work (cf the above code), but !<currency-name> is the recommended way.
			if (msg == "!"+cur) return G->G->commands->currency(this, person, "");
			if (sscanf(msg, "!"+cur+" %s", string param) == 1) return G->G->commands->currency(this, person, param);
		}
		if (string response = G->G->echocommands[msg]) return response;
		if (string response = sscanf(msg, "%s %s", string cmd, string param) && G->G->echocommands[cmd])
			return replace(response, "%s", param);
	}

	void not_message(object person,string msg)
	{
		if (lower_case(person->nick) == lower_case(G->config->nick)) lastmsgtime = time(1);
		string response = handle_command(person, msg);
		if (response) send_message(name, replace(response, "$$", person->user));
		if (sscanf(msg, "\1ACTION %s\1", string slashme)) msg = person->nick+" "+slashme;
		else msg = person->nick+": "+msg;
		string pfx=sprintf("[%s] ",name);
		int wid = Stdio.stdin->tcgetattr()->columns - sizeof(pfx);
		log("%s%s\e[0m", color, sprintf("%*s%-=*s\n",sizeof(pfx),pfx,wid,msg));
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
}

void create()
{
	G->config->channel_program = channel_notif;
	G->config->connection_lost = reconnect;
	if (!G->G->channelcolor) G->G->channelcolor = ([]);
	irc = G->G->irc;
	if (irc) destruct(irc); //HACK: Force reconnection every time
	reconnect();
	add_constant("send_message", send_message);
}
