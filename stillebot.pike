/* Chat bot for Twitch.tv
See API docs:
https://dev.twitch.tv/docs/v5/

Requires OAuth authentication, which is by default handled by the GUI.
*/

array(string) bootstrap_files = ({"persist.pike", "globals.pike", "poll.pike", "connection.pike", "console.pike", "window.pike", "modules", "zz_local"});
mapping G = ([]);
function(string:void) execcommand;

void console(object stdin, string buf)
{
	while (has_value(buf, "\n"))
	{
		sscanf(buf, "%s\n%s", string line, buf);
		execcommand(line);
	}
	if (buf!="") execcommand(buf);
}

object bootstrap(string c)
{
	program|object compiled;
	mixed ex=catch {compiled=compile_file(c);};
	if (ex) {werror("Exception in compile!\n"); werror(ex->describe()+"\n"); return 0;}
	if (!compiled) werror("Compilation failed for "+c+"\n");
	if (mixed ex=catch {compiled = compiled(c);}) werror(describe_backtrace(ex)+"\n");
	werror("Bootstrapped "+c+"\n");
	return compiled;
}

int bootstrap_all()
{
	object main = bootstrap(__FILE__);
	if (!main || !main->bootstrap_files) {werror("UNABLE TO RESET ALL\n"); return 1;}
	int err = 0;
	foreach (bootstrap_files = main->bootstrap_files, string fn)
		if (file_stat(fn)->isdir)
		{
			foreach (sort(get_dir(fn)), string f)
				if (has_suffix(f, ".pike")) err += !bootstrap(fn + "/" + f);
		}
		else err += !bootstrap(fn);
	return err;
}

int main(int argc,array(string) argv)
{
	add_constant("G", this);
	G->argv = argv;
	bootstrap_all();
	foreach ("persist_config command send_message window" / " ", string vital)
		if (!all_constants()[vital])
			exit(1, "Vital core files failed to compile, cannot continue.\n");
	//Compat: Import settings from the old text config
	if (file_stat("twitchbot_config.txt"))
	{
		mapping config = ([]);
		foreach (Stdio.read_file("twitchbot_config.txt")/"\n", string l)
		{
			l = String.trim_all_whites(l); //Trim off carriage returns as needed
			if (l=="" || l[0]=='#') continue;
			sscanf(l, "%s:%s", string key, string val); if (!val) continue;
			config[key] = String.trim_all_whites(val); //Permit (but don't require) a space after the colon
		}
		if (config->pass[0] == '<') m_delete(config, "pass");
		object persist = all_constants()["persist"]; //Since we can't use the constant as such :)
		persist["ircsettings"] = config;
		persist->dosave(); //Save synchronously before destroying the config file
		if (!persist->saving) rm("twitchbot_config.txt");
	}
	#ifndef __NT__
	//Windows has big problems with read callbacks on both stdin and one or more sockets.
	//(I suspect it's because the select() function works on sockets, not file descriptors.)
	//Since this is just for debug/emergency anyway, we just suppress it; worst case, you
	//have to restart StilleBot in a situation where an update would have been sufficient.
	Stdio.stdin->set_read_callback(console);
	#endif
	return -1;
}
