void data_available(object q, function cbdata) {cbdata(q->unicode_data());}
void request_ok(object q, function cbdata) {q->async_fetch(data_available, cbdata);}
void request_fail(object q) { } //If a poll request fails, just ignore it and let the next poll pick it up.
void make_request(string url, function cbdata)
{
	Protocols.HTTP.do_async_method("GET",url,0,0,
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
		}
	}
	else
	{
		G->G->channel_info[name] = info->stream->channel; //Take advantage of what we're given and update our cache with a single request
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->stream->created_at);
		if (!G->G->stream_online_since[name])
		{
			//Is there a cleaner way to say "convert to local time"?
			object started_here = started->set_timezone(Calendar.now()->timezone());
			write("** Channel %s went online at %s **\n", name, started_here->format_nice());
			if (object chan = G->G->irc->channels["#"+name])
				chan->save(started->unix_time());
		}
		G->G->stream_online_since[name] = started;
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

void create()
{
	if (!G->G->stream_online_since) G->G->stream_online_since = ([]);
	if (!G->G->channel_info) G->G->channel_info = ([]);
	remove_call_out(G->G->poll_call_out);
	add_constant("get_channel_info", get_channel_info);
	add_constant("check_following", check_following);
}
