inherit command;
constant require_allcmds = 1;

string process(object channel, object person, string param)
{
	array(string) cmds = ("!"+indices(G->G->commands)[*]) + indices(G->G->echocommands);
	return "@$$: Available commands are: " + sort(cmds) * " ";
}

