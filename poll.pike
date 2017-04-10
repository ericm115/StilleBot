//Can be invoked from the command line for tools or interactive API inspection.

void data_available(object q, function cbdata) {cbdata(q->unicode_data());}
void request_ok(object q, function cbdata) {q->async_fetch(data_available, cbdata);}
void request_fail(object q) { } //If a poll request fails, just ignore it and let the next poll pick it up.
void make_request(string url, function cbdata)
{
	sscanf(persist["ircsettings"]["pass"] || "", "oauth:%s", string pass);
	Protocols.HTTP.do_async_method("GET",url,0,
		pass && (["Authorization": "OAuth " + pass]),
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
		sscanf(info->_links->self, "https://api.twitch.tv/kraken/channels/%s", string name);
		if (!G->G->channel_info[name]) G->G->channel_info[name] = info;
		if (callback) callback(info, @cbargs);
	}
}

void streaminfo(string data)
{
	mapping info; catch {info = Standards.JSON.decode(data);}; //Some error returns aren't even JSON
	if (!info || info->error) return; //Ignore the 503s and stuff that come back.
	sscanf(info->_links->self, "https://api.twitch.tv/kraken/streams/%s", string name);
	if (!info->stream)
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
			runhooks("channel-offline", name);
			mapping vstat = m_delete(G->G->viewer_stats, name);
			if (sizeof(vstat->half_hour) == 30)
			{
				mapping config = persist["channels"][name];
				config->stream_stats += ({([
					"start": vstat->start, "end": time(),
					"viewers_high": vstat->high_half_hour,
					"viewers_low": vstat->low_half_hour,
				])});
				persist->save();
			}
		}
	}
	else
	{
		//TODO: Report when the game changes?
		G->G->channel_info[name] = info->stream->channel; //Take advantage of what we're given and update our cache with a single request
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->stream->created_at);
		if (!G->G->stream_online_since[name])
		{
			//Is there a cleaner way to say "convert to local time"?
			object started_here = started->set_timezone(Calendar.now()->timezone());
			write("** Channel %s went online at %s **\n", name, started_here->format_nice());
			if (object chan = G->G->irc->channels["#"+name])
				chan->save(started->unix_time());
			runhooks("channel-online", name);
		}
		G->G->stream_online_since[name] = started;
		int viewers = info->stream->viewers;
		//Calculate half-hour rolling average, and then do stats on that
		//Record each stream's highest and lowest half-hour average, and maybe the overall average (not the average of the averages)
		//TODO: Offer a graph showing the channel's progress
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
	//write("%O\n", G->G->stream_online_since);
	//write("%s: %O\n", name, info->stream);
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

void poll()
{
	G->G->poll_call_out = call_out(poll, 60); //TODO: Make the poll interval customizable
	foreach (indices(persist["channels"] || ({ })), string chan)
		make_request("https://api.twitch.tv/kraken/streams/"+chan, streaminfo);
}

void create()
{
	if (!G->G->stream_online_since) G->G->stream_online_since = ([]);
	if (!G->G->channel_info) G->G->channel_info = ([]);
	remove_call_out(G->G->poll_call_out);
	poll();
	add_constant("get_channel_info", get_channel_info);
	add_constant("check_following", check_following);
}

#if !constant(G)
mapping G = (["G":([])]);
mapping persist = (["channels": ({ }), "ircsettings": Standards.JSON.decode_utf8(Stdio.read_file("twitchbot_config.json"))["ircsettings"] || ([])]);
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
int req(string url) //Returns 0 to suppress Hilfe warning.
{
	if (!has_prefix(url, "http")) url = "https://api.twitch.tv/kraken/" + url[url[0]=='/'..];
	make_request(url, interactive);
}

void streaminfo_display(string data)
{
	mapping info = decode(data); if (!info) return;
	sscanf(info->_links->self, "https://api.twitch.tv/kraken/streams/%s", string name);
	if (info->stream)
	{
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->stream->created_at);
		write("Channel %s went online at %s\n", name, started->format_nice());
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
		write("%{%s\n%}", reverse(games));
	}
	else write("No games online.\n");
	exit(0);
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
		make_request("https://api.twitch.tv/kraken/streams?language=tr&limit=100&stream_type=live", show_turkish);
		return -1;
	}
	requests = argc * 2 - 2;
	foreach (argv[1..], string chan)
	{
		if (sscanf(chan, "%s/%s", string ch, string user) && user)
		{
			write("Checking follow status...\n");
			--requests; //These count as only one, not two
			check_following(user, ch, followinfo_display);
		}
		else
		{
			//For online channels, we could save ourselves one request. Simpler to just do 'em all though.
			make_request("https://api.twitch.tv/kraken/streams/"+chan, streaminfo_display);
			make_request("https://api.twitch.tv/kraken/channels/"+chan, chaninfo_display);
		}
	}
	return requests && -1;
}
#endif
