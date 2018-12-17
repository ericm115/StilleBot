inherit command;
constant require_moderator = 1;

void autospam(string channel, string msg)
{
	if (function f = bounce(this_function)) return f(channel, msg);
	werror("Online: %O\n", G->G->stream_online_since[channel[1..]]);
	//if (!G->G->stream_online_since[channel[1..]]) return;
	mapping cfg = persist_config["channels"][channel[1..]];
	if (!cfg) return; //Channel no longer configured
	int mins = cfg->autocommands[msg];
	if (!mins) return; //Autocommand disabled
	string key = channel + " " + msg;
	//~ G->G->autocommands[key] = call_out(autospam, mins * 60 - 60 + random(120), channel, msg); //plus or minus a minute
	//G->G->autocommands[key] = call_out(autospam, mins, channel, msg); //hack
	send_message(channel, "*+* " + msg);
}

int connected(string channel)
{
	//TODO: Start all timers for this channel at random(delay*60-60)+60
}

echoable_message process(object channel, object person, string param)
{
	//TODO: "!repeat 10 Hello, world" to pop out "Hello, world" every
	//10 +/- 1 minutes. If it begins !, run that command instead.
	if (param == "")
	{
		//TODO: Report all current repeated messages
		return "(unimpl)";
	}
	sscanf(param, "%d %s", int mins, string msg);
	if (!mins || !msg) return "Try: !repeat 10 Hello, world"; //TODO: Link to docs on GH Pages, when they exist
	mapping ac = channel->config->autocommands;
	if (!ac) ac = channel->config->autocommands = ([]);
	string key = channel->name + " " + msg;
	if (mins == -1)
	{
		//Normally spelled "!unrepeat some-message" but you can do it
		//as "!repeat -1 some-message" if you really want to
		if (!m_delete(ac, msg)) return "That message wasn't being repeated, and can't be cancelled";
		if (mixed id = m_delete(G->G->autocommands, key))
			remove_call_out(id);
		return "Repeated command disabled.";
	}
	if (mins < 5) return "Minimum five-minute repeat cycle. You should probably keep to a minimum of 20 mins.";
	if (mixed id = m_delete(G->G->autocommands, key))
		remove_call_out(id);
	ac[msg] = mins;
	G->G->autocommands[key] = call_out(autospam, mins /* * 60 */, channel->name, msg);
	return "Added to the repetition table.";
}

echoable_message unrepeat(object channel, object person, string param)
{
	return process(channel, person, "-1 " + param);
}

void check_autocommands()
{
	//First look for any that should be removed
	//No need to worry about channels being offline; they'll be caught at next repeat.
	foreach (G->G->autocommands; string key; mixed id)
	{
		sscanf(key, "%s %s", string channel, string msg);
		mapping cfg = persist_config["channels"][channel[1..]];
		if (!cfg || !cfg->autocommands[msg])
			remove_call_out(m_delete(G->G->autocommands, key));
	}
	//Next, look for any that need to be started.
	foreach (persist["channels"]; string channel; mapping cfg)
	{
		foreach (cfg->autocommands || ([]); string msg; int mins)
		{
			string key = "#" + channel + " " + msg;
			mixed id = G->G->autocommands[key];
			if (!id || undefinedp(find_call_out(id)))
				G->G->autocommands[key] = call_out(autospam, mins /* * 60 */, "#" + channel, msg);
		}
	}
}

void create(string name)
{
	register_hook("channel-online", connected);
	register_bouncer(autospam);
	if (!G->G->autocommands) G->G->autocommands = ([]);
	else check_autocommands();
	G->G->commands["unrepeat"] = unrepeat;
	::create(name);
}
