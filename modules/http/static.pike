inherit http_endpoint;

constant http_path_pattern = "/static/%[^/]";
mapping(string:mixed) http_request(Protocols.HTTP.Server.Request req, string filename)
{
	//TODO: Handle static files eg CSS
	if (filename == "" || has_prefix(filename, ".")) return (["error": 403, "data": "Forbidden"]);
	//For absolute paranoia-level safety, instead of trying to open the
	//file directly, we check that the name comes up in a directory listing.
	if (!has_value(get_dir("httpstatic"), filename)) return (["error": 404, "data": "Not found"]);
	//TODO: Play nicely with caches by providing an etag
	return (["file": Stdio.File("httpstatic/" + filename)]);
}
