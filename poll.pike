void data_available(object q, function cbdata) {cbdata(q->unicode_data());}
void request_ok(object q, function cbdata) {q->async_fetch(data_available, cbdata);}
void request_fail(object q) { } //If a poll request fails, just ignore it and let the next poll pick it up.
void make_request(string url, function cbdata)
{
	Protocols.HTTP.do_async_method("GET",url,0,0,
		Protocols.HTTP.Query()->set_callbacks(request_ok,request_fail,cbdata));
}

void streaminfo(string data)
{
	mapping info = Standards.JSON.decode(data);
	sscanf(info->_links->self, "https://api.twitch.tv/kraken/streams/%s", string name);
	if (!info->stream)
	{
		if (m_delete(G->G->stream_online_since, name))
		{
			write("** Channel %s noticed offline at %s **\n", name, Calendar.now()->format_nice());
			if (object chan = G->G->irc->channels["#"+name])
				chan->save(); //We don't get the offline time, so we'll pretend it was online all up until we noticed.
		}
	}
	else
	{
		G->G->channel_info[name] = info->stream->channel; //Not cleared when the stream goes offline - this will retain "last sighted" info.
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->stream->created_at);
		if (!G->G->stream_online_since[name])
		{
			write("** Channel %s went online at %s **\n", name, started->format_nice());
			if (object chan = G->G->irc->channels["#"+name])
				chan->save(started->unix_time());
		}
		G->G->stream_online_since[name] = started;
	}
	//write("%O\n", G->G->stream_online_since);
	//write("%s: %O\n", name, info->stream);
}

void poll()
{
	G->G->poll_call_out = call_out(poll, 60); //TODO: Make the poll interval customizable
	foreach (indices(persist["channels"]), string chan)
		make_request("https://api.twitch.tv/kraken/streams/"+chan, streaminfo);
}

void create()
{
	if (!G->G->stream_online_since) G->G->stream_online_since = ([]);
	if (!G->G->channel_info) G->G->channel_info = ([]);
	remove_call_out(G->G->poll_call_out);
	poll();
}

#if !constant(G)
mapping G = (["G":([])]);
mapping persist = (["channels": ({ })]);

int streams;
void streaminfo_display(string data)
{
	mapping info = Standards.JSON.decode(data);
	sscanf(info->_links->self, "https://api.twitch.tv/kraken/streams/%s", string name);
	if (info->stream)
	{
		object started = Calendar.parse("%Y-%M-%DT%h:%m:%s%z", info->stream->created_at);
		write("Channel %s went online at %s\n", name, started->format_nice());
	}
	else write("Channel %s is offline.\n", name);
	if (!--streams) exit(0);
}
int main(int argc, array(string) argv)
{
	streams = argc-1;
	foreach (argv[1..], string chan)
		make_request("https://api.twitch.tv/kraken/streams/"+chan, streaminfo_display);
	return streams && -1;
}
#endif