inherit command;
constant docstring = #"
List commands available to you

This command will list every command that you have permission to use in the
channel you are in, apart from hidden commands.

You can also use \"!help !somecommand\" to get additional information on any
command.
";

echoable_message process(object channel, mapping person, string param)
{
	multiset(string) cmds = (<>);
	int is_mod = channel->mods[person->user];
	if (param != "")
	{
		//NOTE: We say "mod-only" if a mod command comes up when a non-mod one
		//doesn't, even if that's not quite the case. There could be edge cases.
		sscanf(param, "%*[ !]%s%*[ ]", param);
		string modonly = "";
		echoable_message cmd = find_command(channel, param, 0);
		if (!cmd) {cmd = find_command(channel, param, 1); modonly = " mod-only";}
		if (!cmd) return "@$$: That isn't a command in this channel, so far as I can tell.";
		if (!functionp(cmd))
		{
			//Do I need any more info? Maybe check if it's a mapping to see if it has a defaultdest?
			return sprintf("@$$: !%s is an echo command - see https://rosuav.github.io/StilleBot/commands/addcmd", param);
		}
		object obj = function_object([function]cmd);
		string pgm = sprintf("%O", object_program(obj)) - ".pike"; //For some reason function_name isn't giving me the right result (??)
		return sprintf("@$$: !%s is a%s%s%s command.%s", param,
			!obj->docstring ? "n undocumented ": "",
			obj->hidden_command ? " hidden": "",
			modonly,
			obj->docstring && !obj->hidden_command ? " Learn more at https://rosuav.github.io/StilleBot/commands/" + pgm : "",
		);
	}
	foreach (({G->G->commands, G->G->echocommands}), mapping commands)
		foreach (commands; string cmd; string|function handler)
		{
			//Note that we support strings and functions in both mappings.
			//Actual command execution isn't currently quite this flexible,
			//assuming that functions are in G->G->commands and strings are
			//in G->G->echocommands. It may be worth making execution more
			//flexible, which might simplify some multi-command modules.
			object|mapping flags =
				//Availability flags come from the providing object, normally.
				functionp(handler) ? function_object(handler) :
				//String commands use these default flags.
				(["all_channels": 0, "require_moderator": 0, "hidden_command": 0]);
			if (flags->hidden_command) continue;
			if (!flags->all_channels && !channel->config->allcmds) continue;
			if (flags->require_moderator && !is_mod) continue;
			if (has_prefix(cmd, "!")) continue; //Special responses aren't commands
			if (!has_value(cmd, '#') || has_suffix(cmd, channel->name))
				cmds[cmd - channel->name] = 1;
		}
	//Hack: !currency is invoked as !chocolates when the currency name
	//is "chocolates", and shouldn't be invoked at all if there's no
	//channel currency here.
	cmds["currency"] = 0;
	string cur = channel->config->currency;
	if (cur && cur != "") cmds[cur] = 1;
	string local_info = "";
	if (string addr = persist_config["ircsettings"]->http_address)
		local_info = " You can also view further information about this specific channel at " + addr + "/channels/" + channel->name[1..];
	return ({"@$$: Available commands are: " + ("!"+sort(indices(cmds))[*]) * " ",
		"For additional information, see https://rosuav.github.io/StilleBot/commands/" + local_info});
}
