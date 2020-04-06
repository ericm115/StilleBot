inherit http_endpoint;

mapping(string:mixed) http_request(Protocols.HTTP.Server.Request req)
{
	array quotes = req->misc->channel->config->quotes;
	if (!quotes || !sizeof(quotes)) return render_template("chan_quotes.md", (["channel": req->misc->channel_name, "quotes": "(none)", "editjs": ""]));
	string editjs = "";
	if (req->misc->is_mod)
	{
		//All the work is done client-side
		editjs = "<script>const quotes = " + Standards.JSON.encode(quotes) + "</script>"
			"<script type=module src=\"/static/quotes.js\"></script>";
	}
	array q = ({ });
	string tz = req->misc->channel->config->timezone;
	object user = user_text();
	mapping emotes;
	if (G->G->emote_set_mapping)
	{
		emotes = ([]);
		//What if there's a collision? Should we prioritize?
		foreach (G->G->bot_emote_list->emoticon_sets;; array set) foreach (set, mapping em)
			emotes[em->code] = sprintf("![%s](https://static-cdn.jtvnw.net/emoticons/v1/%d/1.0)", em->code, em->id);
	}
	foreach (quotes; int i; mapping quote)
	{
		//Render emotes. TODO: Use the bot's emote list primarily, but
		//if we have emote info retained from addquote, use that too.
		object ts = Calendar.Gregorian.Second("unix", quote->timestamp);
		if (tz) ts = ts->set_timezone(tz) || ts;
		string msg;
		if (emotes)
		{
			array words = quote->msg / " ";
			//This is pretty inefficient - it makes a separate user() entry for each
			//individual word. If this is a problem, consider at least checking for
			//any emotes at all, and if not, do the else instead.
			foreach (words; int i; string w)
				words[i] = emotes[w] || user(w);
			msg = words * " ";
		}
		else msg = user(quote->msg);
		string date = sprintf("%d %s %d", ts->month_day(), ts->month_name(), ts->year_no());
		q += ({sprintf("%d. %s [%s, %s]", i + 1, msg, quote->game || "uncategorized", date)});
	}
	return render_template("chan_quotes.md", ([
		"channel": req->misc->channel_name,
		"quotes": q * "\n",
		"editjs": editjs,
		"user text": user,
	]));
}
