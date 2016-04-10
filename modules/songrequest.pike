inherit command;
constant require_allcmds = 1;
/* Currently a stub for notetaking.

Proposal: Implement song requests using a download cache and VLC.

This will require:
* Downloader, triggered by the !songrequest command (this one)
* Global queue of requested songs
* Player

The queue needs to acknowledge that a file may not yet have been fully
downloaded. TODO: How do we detect broken files? Can we have youtube-dl
not give them the final file names until it's confident? (It already has
the concept of .part files for ones that aren't fully downloaded. This
MAY be sufficient.) TODO: Allow mods to say "!songrequest force youtubeid"
to delete and force redownloading.

The player is pretty simple. Invoke "cvlc --play-and-exit filename.m4a"
and have an event on its termination. Edge cases: There might not be any
currently-downloaded files (eg on first song request), so the downloader
may need to trigger the player. Also, it's entirely possible for playback
to stall; might need a mod-only command to kill it and start the next
track (maybe that can just be called !nextsong or something).

TODO: Flexible system for permitting/denying song requests. For example,
permit mods only, or followers/subs only (once StilleBot learns about
who's followed/subbed); channel currency cost, which could be different
for different people ("subscribers can request songs for free"); and
maybe even outright bannings ("FredTheTroll did nothing but rickroll us,
so he's not allowed to request songs any more").
*/

mapping(string:array) read_cache()
{
	mapping(string:array) cache = ([]);
	foreach (get_dir("song_cache"), string fn)
	{
		if (fn == "README") continue;
		sscanf(fn, "%d-%s-%s", int len, string id, string title);
		if (has_suffix(title, ".part")) continue; //Ignore partial files
		cache[id] = ({len, title, fn, id});
	}
	return cache;
}

void check_queue()
{
	if (check_queue != G->G->check_queue) {G->G->check_queue(); return;}
	object p = G->G->songrequest_player;
	if (p && !p->status()) return; //Already playing something.
	m_delete(G->G, "songrequest_nowplaying");
	mapping(string:array) cache = read_cache();
	string fn = 0;
	foreach (persist["songrequests"], string song)
	{
		if (G->G->songrequest_downloading[song]) continue; //Can't play if still downloading (or can we??)
		persist["songrequests"] -= ({song});
		if (!cache[song]) continue; //Not in cache and not downloading. Presumably the download failed - drop it.
		//Okay, so we can play this one.
		G->G->songrequest_nowplaying = cache[song];
		fn = "song_cache/"+cache[song][2];
		break;
	}
	if (!fn && sizeof(G->G->songrequest_playlist))
		//Nothing in song request queue, but we have a playlist.
		[fn, G->G->songrequest_playlist] = Array.shift(G->G->songrequest_playlist);
	if (fn)
		//We have something to play!
		G->G->songrequest_player = Process.create_process(
			({"cvlc", "--play-and-exit", fn}),
			([
				"callback": check_queue,
				"stdout": Stdio.File("/dev/null", "w")->pipe(Stdio.PROP_IPC),
				"stderr": Stdio.File("/dev/null", "w")->pipe(Stdio.PROP_IPC),
			])
		);
}

class youtube_dl(string videoid, string requser)
{
	inherit Process.create_process;
	Stdio.File stdout, stderr;
	string reqchan;

	void create(object channel)
	{
		reqchan = channel->name;
		stdout = Stdio.File(); stderr = Stdio.File();
		stdout->set_read_callback(data_received);
		::create(
			({"youtube-dl",
				"--prefer-ffmpeg", "-f","bestaudio",
				"-o","%(duration)s-%(id)s-%(title)s", "--match-filter","duration < "+channel->config->songreq_length,
				videoid
			}),
			([
				"callback": download_complete,
				"cwd": "song_cache",
				"stdout": stdout->pipe(Stdio.PROP_IPC|Stdio.PROP_NONBLOCK),
			])
		);
	}

	void data_received(mixed id, string data)
	{
		if (sscanf(data, "[download] %s does not pass filter duration < %d, skipping", string title, int maxlen))
		{
			send_message(reqchan, sprintf("@%s: Video too long [max = %s]: %s", requser, describe_time(maxlen), title));
			return;
		}
		werror("youtube-dl for %s: %O\n", videoid, data);
	}

	void download_complete()
	{
		wait();
		stdout->close();
		stderr->close();
		m_delete(G->G->songrequest_downloading, videoid);
		check_queue();
	}
}

string process(object channel, object person, string param)
{
	if (!channel->config->songreq) return "@$$: Song requests are not currently active.";
	if (!G->G->stream_online_since[channel->name[1..]]) return "@$$: Song requests are available only while the channel is online.";
	werror("songrequest: %O\n", param);
	if (param == "status" && channel->mods[person->user])
	{
		foreach (sort(get_dir("song_cache")), string fn)
		{
			if (fn == "README") continue;
			sscanf(fn, "%d-%s-%s", int len, string id, string title);
			int partial = has_suffix(title, ".part"); if (partial) title = title[..<5];
			send_message(channel->name, sprintf("%s: [%s]: %s %O",
				partial ? "Partial download" : "Cached file",
				describe_time(len), id, title));
		}
		foreach (G->G->songrequest_downloading; string videoid; object proc)
			send_message(channel->name, "Currently downloading "+videoid+": status "+proc->status());
		if (array x=G->G->songrequest_nowplaying)
			send_message(channel->name, sprintf("Now playing [%s]: %O", describe_time(x[0]), x[1]));
		return "Song queue: "+persist["songrequests"]*", ";
	}
	if (param == "skip" && channel->mods[person->user])
	{
		object p = G->G->songrequest_player;
		if (!p) return "@$$: Nothing currently playing.";
		p->kill(2); //Send SIGINT
		return "@$$: Song skipped.";
	}
	if (param == "flush" && channel->mods[person->user])
	{
		persist["songrequests"] = ({ });
		return "@$$: Song request queue flushed. After current song, silence.";
	}
	if (sizeof(param) != 11) return "@$$: Try !songrequest YOUTUBE-ID";
	if (G->G->songrequest_nowplaying && G->G->songrequest_nowplaying[3] == param)
		return "@$$: That's what's currently playing!";
	if (has_value(persist["songrequests"], param)) return "@$$: Song is already in the queue";
	mapping cache = read_cache();
	if (array info = cache[param])
	{
		if (info[0] > channel->config->songreq_length) return "@$$: Song too long to request [cache hit]";
		persist["songrequests"] += ({param});
		check_queue();
		return "@$$: Added to queue [cache hit]";
	}
	persist["songrequests"] += ({param});
	if (G->G->songrequest_downloading[param]) return "@$$: Added to queue [already downloading]";
	G->G->songrequest_downloading[param] = youtube_dl(param, person->user, channel);
	return "@$$: Added to queue [download started]";
}

void create(string name)
{
	::create(name);
	//NOTE: Do not create a *file* called song_cache, as it'll mess with this :)
	if (!file_stat("song_cache"))
	{
		mkdir("song_cache");
		Stdio.write_file("song_cache/README", #"Requested song cache

Files in this directory have been downloaded by and in response to the !songrequest
command. See modules/songrequest.pike for more information. Any time StilleBot is
not running song requests, the contents of this directory can be freely deleted.
");
	}
	if (!G->G->songrequest_downloading) G->G->songrequest_downloading = ([]);
	if (!G->G->songrequest_playlist) G->G->songrequest_playlist = ({ });
	if (!persist["songrequests"]) persist["songrequests"] = ({ });
	G->G->check_queue = check_queue;
}
