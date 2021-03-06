inherit command;
constant require_allcmds = 1;
inherit menu_item;
constant menu_label = "Song requests";
constant hidden_command = 1;
constant active_channels = ({"rosuav"});
inherit websocket_handler;
//TODO-DOCSTRING
/* Song requests with a download cache and VLC.

The queue needs to acknowledge that a file may not yet have been fully
downloaded. TODO: How do we detect broken files? Can we have youtube-dl
not give them the final file names until it's confident? (It already has
the concept of .part files for ones that aren't fully downloaded. This
MAY be sufficient.) TODO: Allow mods to say "!songrequest force youtubeid"
to delete and force redownloading.

The player invokes VLC (with its full default interface, giving manual
control eg of volume) and connects to its STDIN control interface. Newly
added tracks are enqueued, and whenever one finishes, the status will be
updated.

TODO: As of 20170717, the player has a GUI. Should we download video as
well as audio?

TODO: Flexible system for permitting/denying song requests. For example,
permit mods only, or followers/subs only (once StilleBot learns about
who's followed/subbed); channel currency cost, which could be different
for different people ("subscribers can request songs for free"); and
maybe even outright bannings ("FredTheTroll did nothing but rickroll us,
so he's not allowed to request songs any more").

TODO: Allow browser-based song requests rather than VLC-based.
- Don't download all the content. Just use youtube-dl --get-filename,
  which should be sufficient to get basic metadata (length, track name)
  and then feed the YT ID to all connected websockets for this channel.
- The websocket connections will need to specify a channel
- If the user is allowed to control playback that way, there'll need to
  be authentication on the web end - tie in with /twitchlogin, but maybe
  require that it be the streamer specifically? Or make the URL include
  the channel name (/rosuav/songreq and /rosuav/songqueue)? It might be
  cleanest to let mods control it same as the streamer does.
- Make sure there are no global (non-per-channel) statuses that would be
  broken by this. It's okay to assume max of one VLC player though.
*/

Stdio.File nullfile()
{
	//Is there a cross-platform way to find the null device? Python has os.devnull for that.
	#ifdef __NT__
	return Stdio.File("nul", "wct");
	#else
	return Stdio.File("/dev/null", "wct");
	#endif
}
Stdio.File nullpipe() {return nullfile()->pipe(Stdio.PROP_IPC);}

void statusfile()
{
	array nowplaying = G->G->songrequest_nowplaying;
	string msg;
	if (nowplaying)
	{
		msg = sprintf("[%s] %s", describe_time_short(nowplaying[0]), nowplaying[1]);
		//Locate the metadata block by scanning backwards.
		//There'll be meta entries for all requests, moving forward. There may be
		//any number of meta entries *behind* the current request, so always count back.
		mapping meta = persist_status["songrequest_meta"][-1-sizeof(persist_status["songrequests"])];
		msg += sprintf("\nRequested by %s at %s", meta->by, ctime(meta->at)[..<1]);
	}
	else
	{
		//Not playing any requested song. Maybe we have a playlist song.
		//We don't track lengths of those, though.
		if (G->G->songrequest_player) msg = explode_path(G->G->songrequest_lastplayed)[-1];
		else msg = "(nothing)";
	}
	Stdio.write_file("song_cache/nowplaying.txt", msg + "\n");
	G->G->songrequest_nowplaying_info = msg;
}

array(function) status_update = ({statusfile}); //Call this to update all open status windows (and the status file)

mapping(string:array) read_cache()
{
	mapping(string:array) cache = ([]);
	foreach (get_dir("song_cache"), string fn)
	{
		if ((<"README", "nowplaying.txt">)[fn]) continue;
		sscanf(fn, "%d-%11[^\n]-%s", int len, string id, string title);
		if (has_suffix(title, ".part")) continue; //Ignore partial files
		cache[id] = ({len, title, fn, id});
	}
	return cache;
}

mixed check_call_out;
void vlc_stdin(mixed id, string data)
{
	if (vlc_stdin != G->G->vlc_stdin) {G->G->vlc_stdin(id, data); return;}
	while (sscanf(data, "%*s+----[ CLI commands matching `marker' ]\r\n+----[ end of help ]\r\n%s> %s", string response, data))
	{
		sscanf(response, "%d\r\n%s", G->G->songrequest_active, string info);
		int length, time;
		if (G->G->songrequest_active) sscanf(info, "%d\r\n%d\r\n", length, time); //Otherwise they're invalid info, so just use 0 and 0.
		int delay = (length - time) / 2;
		if (delay < 1) delay = 1; //Never hammer the pipe (that's an interesting visual)
		if (delay > 30) delay = 30; //Periodically re-check
		check_call_out = call_out(check_queue, delay);
	}
}

void check_queue()
{
	if (check_call_out) {remove_call_out(check_call_out); check_call_out = 0;}
	if (check_queue != G->G->check_queue) {G->G->check_queue(); return;}
	object p = G->G->songrequest_player;
	if (p && p->status() == 2) {
		//Process has ended. Reap it cleanly.
		p->wait();
		p = 0;
		m_delete(G->G, "songrequest_player");
	}
	m_delete(G->G, "songrequest_nowplaying");
	call_out(status_update, 0);
	if (string chan = G->G->songrequest_channel)
	{
		//Disable song requests once the channel's offline or has song reqs disabled
		if (!persist_config["channels"][chan]->songreq //Song requests are not currently active.
			||!G->G->stream_online_since[chan]) //Song requests are available only while the channel is online.
		{
			if (p) G->G->songrequest_stdin->write("quit\n");
			return;
		}
	}
	//Check if something's currently being played.
	if (p)
	{
		G->G->songrequest_stdin->write("help marker\nis_playing\nget_length\nget_time\n");
		//Should be two possibilities:
		//1) "0\r\n\r\n\r\n" (ie "0" and two blanks) - not playing
		//2) "1\r\nNNN\r\nMMM\r\n" (three numbers; NNN >= MMM) - playing
		//Either way, there'll be a "> " when we're done
		if (G->G->songrequest_active) return;
	}
	mapping(string:array) cache = read_cache();
	string fn = 0;
	foreach (persist_status["songrequests"], string song)
	{
		if (G->G->songrequest_downloading[song]) continue; //Can't play if still downloading (or can we??)
		persist_status["songrequests"] -= ({song});
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
	{
		G->G->songrequest_lastplayed = fn;
		G->G->songrequest_started = time();
		//We have something to play!
		if (!p)
		{
			G->G->songrequest_stdout = Stdio.File();
			G->G->songrequest_player = p = Process.create_process(
				//TODO: Make the additional parameters part customizable
				//Useful console commands:
				//enqueue <filename> - when a song is finished downloading
				//next - to veto a song; also hit this immediately after enqueuing onto an empty playlist
				//get_title - find out the currently-playing track
				//get_time - find out how far we are into it (subtract from track length)
				({"vlc", "--no-play-and-exit", "--extraintf", "lua", "--alsa-audio-device", "default"}),
				([
					"callback": check_queue,
					"stdin": (G->G->songrequest_stdin=Stdio.File())->pipe(),
					"stdout": (G->G->songrequest_stdout=Stdio.File())->pipe(),
					"stderr": nullpipe(),
				])
			);
			G->G->songrequest_stdout->set_nonblocking(vlc_stdin, 0);
		}
		G->G->songrequest_stdin->write("enqueue "+fn+"\nnext\n");
		call_out(check_queue, 1);
	}
}

class menu_clicked
{
	inherit window;
	constant is_subwindow = 0;
	protected void create() {::create(); status_update += ({update});}
	void closewindow() {status_update -= ({update}); ::closewindow();}

	void makewindow()
	{
		win->mainwindow=GTK2.Window((["title":"Song request status"]))->add(GTK2.Vbox(0, 10)
			->add(GTK2.Frame("Requested songs")->add(win->songreq=GTK2.Label()))
			->add(GTK2.Frame("Playlist")->add(win->playlist=GTK2.Label()))
			->add(GTK2.Frame("Downloading")->add(win->downloading=GTK2.Label()))
			->add(GTK2.Frame("Now playing")->add(win->nowplaying=GTK2.Label()))
			->add(GTK2.HbuttonBox()
				->add(win->add_playlist=GTK2.Button("Add to playlist"))
				->add(win->check_queue=GTK2.Button("Check queue"))
				->add(win->skip=GTK2.Button("Skip current song"))
				//SIGSTOP doesn't seem to be working. TODO: Investigate.
				//Or better still, send commands over stdin and use the 'rc' interface.
				//->add(win->pause=GTK2.Button("Pause"))
				//->add(win->cont=GTK2.Button("Continue"))
				->add(stock_close())
			)
		);
		update();
	}

	void update()
	{
		string reqs = "";
		mapping(string:array) cache = read_cache();
		foreach (persist_status["songrequests"], string song)
		{
			string downloading = G->G->songrequest_downloading[song] && " (downloading)";
			if (array c = cache[song])
				reqs += sprintf("[%s] %s%s\n", describe_time(c[0]), c[1], downloading || "");
			else
				if (downloading) reqs += song+" (downloading)\n";
		}
		win->songreq->set_text(reqs);
		win->playlist->set_text(G->G->songrequest_playlist*"\n");
		win->downloading->set_text(indices(G->G->songrequest_downloading)*"\n");
		string msg = G->G->songrequest_nowplaying_info;
		if (G->G->songrequest_player) msg += "\nBeen playing "+describe_time_short(time() - G->G->songrequest_started);
		win->nowplaying->set_text(msg || "");
	}

	void sig_add_playlist_clicked()
	{
		object dlg=GTK2.FileChooserDialog("Add file(s) to playlist",win->mainwindow,
			GTK2.FILE_CHOOSER_ACTION_OPEN,({(["text":"Send","id":GTK2.RESPONSE_OK]),(["text":"Cancel","id":GTK2.RESPONSE_CANCEL])})
		)->set_select_multiple(1)->show_all();
		dlg->signal_connect("response",add_playlist_response);
		dlg->set_current_folder(".");
	}

	void add_playlist_response(object dlg,int btn)
	{
		array fn=dlg->get_filenames();
		dlg->destroy();
		if (btn != GTK2.RESPONSE_OK) return;
		G->G->songrequest_playlist += fn;
		update();
	}

	void sig_check_queue_clicked()
	{
		check_queue();
		status_update();
		update();
	}

	void sig_skip_clicked()
	{
		object p = G->G->songrequest_player;
		if (p) G->G->songrequest_stdin->write("stop\n");
		call_out(sig_check_queue_clicked, 0.1);
	}

	//These two aren't working. Not sure why.
	void sig_pause_clicked()
	{
		object p = G->G->songrequest_player;
		if (p) p->kill(signum("SIGSTOP"));
	}
	void sig_cont_clicked()
	{
		object p = G->G->songrequest_player;
		if (p) p->kill(signum("SIGCONT"));
	}
}

class run_process
{
	inherit Process.create_process;
	Stdio.File stdout;
	string data = "";

	protected void create(array command, mapping opts)
	{
		stdout = Stdio.File();
		stdout->set_read_callback(data_received);
		::create(command, opts + ([
			"callback": process_done,
			"stdout": stdout->pipe(Stdio.PROP_IPC|Stdio.PROP_NONBLOCK),
		]));
	}

	void data_received(mixed id, string partialdata) {data += partialdata;}

	//Override this to be notified on completion.
	void process_done()
	{
		wait();
		stdout->close();
	}
}

//I guess this is proof that classes are a poor man's closures. Or is it proof that
//closures are a poor man's classes?
class get_video_length(string reqchan, string requser, int maxlen, string title)
{
	inherit run_process;
	protected void create(string videoid)
	{
		::create(({"youtube-dl", "--prefer-ffmpeg", "--get-duration", videoid}), ([]));
	}
	void process_done()
	{
		::process_done();
		send_message(reqchan, sprintf("@%s: Video too long [%s, max %s]: %s",
			requser, String.trim_all_whites(data), describe_time_short(maxlen), title || "(unknown)"));
	}
}

class youtube_dl(string videoid, string requser)
{
	inherit run_process;
	string reqchan;

	protected void create(object channel)
	{
		reqchan = channel->name;
		::create(
			({"youtube-dl",
				"--prefer-ffmpeg", "-f","bestaudio",
				"-o", "%(duration)s-%(id)s-%(title)s",
				"--match-filter", "duration < " + channel->config->songreq_length,
				videoid
			}),
			(["cwd": "song_cache"])
		);
	}

	void process_done()
	{
		::process_done();
		m_delete(G->G->songrequest_downloading, videoid);
		check_queue();
		if (sscanf(data, "%*s\n[download] %s does not pass filter duration < %d, skipping", string title, int maxlen) && maxlen)
		{
			get_video_length(reqchan, requser, maxlen, title, videoid);
			//NOTE: This does *not* remove the entries from the visible queue, as that would mess with
			//the metadata array. They will be quietly skipped over once they get reached.
		}
	}
}

string process(object channel, object person, string param)
{
	if (!channel->config->songreq) return 0; //"@$$: Song requests are not currently active."; //Keep it quiet.
	if (!G->G->stream_online_since[channel->name[1..]]) return "@$$: Song requests are available only while the channel is online.";
	G->G->songrequest_channel = channel->name[1..];
	if (param == "status" && person->user == channel->name[1..])
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
		return "Song queue: "+persist_status["songrequests"]*", ";
	}
	if (param == "skip" && channel->mods[person->user])
	{
		object p = G->G->songrequest_player;
		if (!p) return "@$$: Nothing currently playing.";
		if (p) G->G->songrequest_stdin->write("stop\n");
		return "@$$: Song skipped.";
	}
	if (param == "flush" && channel->mods[person->user])
	{
		persist_status["songrequests"] = ({ });
		return "@$$: Song request queue flushed. After current song, back to the playlist.";
	}
	//Attempt to parse out a few common link formats
	//TODO: Support sources other than Youtube itself - youtube-dl can.
	//This will require less stringent parsing here, plus a different way of tagging the cache
	sscanf(param, "https://youtu.be/%s", param);
	sscanf(param, "https://www.youtube.com/watch?v=%s", param);
	sscanf(param, "?v=%s", param);
	sscanf(param, "v=%s", param);
	sscanf(param, "%s&", param); //If any of the previous ones has "?v=blah&other-info=junk", trim that off
	if (sizeof(param) != 11) return "@$$: Try !songrequest YOUTUBE-ID";
	if (G->G->songrequest_nowplaying && G->G->songrequest_nowplaying[3] == param)
		return "@$$: That's what's currently playing!";
	if (has_value(persist_status["songrequests"], param)) return "@$$: Song is already in the queue";
	mapping cache = read_cache();
	string msg;
	if (array info = cache[param])
	{
		if (info[0] > channel->config->songreq_length) return "@$$: Song too long to request [cache hit]";
		msg = "@$$: Added to queue [cache hit]";
	}
	else
	{
		if (G->G->songrequest_downloading[param]) msg = "@$$: Added to queue [already downloading]";
		else
		{
			G->G->songrequest_downloading[param] = youtube_dl(param, person->user, channel);
			msg = "@$$: Added to queue [download started]";
		}
	}
	//This is the only place where the queue gets added to.
	//This is, therefore, the place to add a channel currency cost, a restriction
	//on follower/subscriber status, or anything else the channel owner wishes.
	persist_status["songrequests"] += ({param});
	persist_status["songrequest_meta"] += ({(["by": person->user, "at": time()])});
	msg += sprintf(" - song #%d in the queue", sizeof(persist_status["songrequests"]));
	check_queue();
	return msg;
}

void websocket_msg(mapping(string:mixed) conn, mapping(string:mixed) msg)
{
	if (!msg) return; //Don't need to handle socket closures
	mapping reply;
	switch (msg->cmd)
	{
		case "ping": reply = (["cmd": "ping"]); break;
		case "pong": reply = (["cmd": "pong", "pos": msg->pos]); break;
		default: break;
	}
	if (reply) (websocket_groups[conn->group] - ({conn->sock}))->send_text(Standards.JSON.encode(reply));
}

protected void create(string name)
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
	if (!persist_status["songrequests"]) persist_status["songrequests"] = ({ });
	if (!persist_status["songrequest_meta"]) persist_status["songrequest_meta"] = ({ });
	G->G->check_queue = check_queue;
	G->G->vlc_stdin = vlc_stdin;
}
