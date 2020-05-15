inherit http_endpoint;
/* Raid target finder
  - Show tags (especially language tags) in follow list
  - Show how many viewers *you* have, somewhere.
  - Look up recent raids and show the date/time of the last sighted raid
  - Works only for channels that I track, but I don't have to bot for them.
  - Identify people by user ID if poss, not channel name
  - Also log incoming raids perhaps? Would be useful for other reasons too.
    - There's not going to be any easy UI for it, but it'd be great to have a "raided my friend"
      feature, where we can see any time that X raided Y where Y is one of my friends... hard.
  - Might also be worth showing anyone in the same category you're currently in.
  - Also show your followed categories, if possible. Both these would be shown separately.
  - https://dev.twitch.tv/docs/api/reference#get-streams
    - Would need to explicitly list all the channels to look up
    - Limited to 100 query IDs. Problem.
    - Provides game IDs (but not actual category names)
    - Provides tag IDs also. Steal code from Mustard Mine to understand them.
    - Scopes required: None
  - https://dev.twitch.tv/docs/v5/reference/streams#get-followed-streams
    - This directly does what I want ("show me all followed streams currently online") but
      doesn't include tags. Might need to use this, and then use Helix to grab the tags.
    - Scopes required: user_read
  - Undocumented https://api.twitch.tv/kraken/users/<userid>/follows/games
    - Lists followed categories. Format is a bit odd but they do seem to include an _id
      (which corresponds to G->G->category_names).
    - Can then use /helix/streams (#get-streams) with game_id (up to ten of them).
    - Scopes required: probably user_read?
*/

mapping(string:mixed)|Concurrent.Future http_request(Protocols.HTTP.Server.Request req)
{
	if (mapping resp = ensure_login(req, "user_read")) return resp;
	return twitch_api_request("https://api.twitch.tv/kraken/streams/followed?limit=100",
			(["Authorization": "OAuth " + req->misc->session->token]))
		->then(lambda(mapping info) {
			return render_template("raidfinder.md", ([
				"backlink": "", "follows": Standards.JSON.encode(info["streams"], Standards.JSON.ASCII_ONLY),
			]));
		});
}
