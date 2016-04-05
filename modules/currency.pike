//Implements !currency, but normally you'll execute this as !<currency-name>
//For example, in Rosuav's channel, the currency is "chocolates", so !chocolates
//will invoke this command.
inherit command;

string process(object channel, object person, string param)
{
	if (!channel->wealth) return 0;
	if (param == "help")
	{
		string offline = "";
		if (int ofl = channel->config->payout_offline)
			offline = sprintf(" while the channel is online, or every %s while offline",
				describe_time(channel->config->payout * ofl));
		//Note that the mod bonus isn't mentioned in "!currency help".
		return sprintf("@$$: Earn %s by hanging out in chat! You earn one every %s%s.",
			channel->config->currency, describe_time(channel->config->payout), offline);
	}
	if (channel->mods[person->user] && sscanf(param, "top%d", int top) && top) //Hidden mod-only command
	{
		array people = indices(channel->wealth);
		array wealth = sort(values(channel->wealth), people);
		people = people[<top-1..]; wealth = wealth[<top-1..];
		string msg = "";
		foreach (people; int i; string person)
			msg = sprintf("; %s: %d%s", person, wealth[i][0], msg);
		return sprintf("@$$: The top %d hoarders of %s are: %s", sizeof(people), channel->config->currency, msg[2..]);
	}
	return sprintf("@$$: You have been with the stream for %s, and have earned %d %s.",
		describe_time(channel->viewertime[person->user][0]),
		channel->wealth[person->user][0], channel->config->currency);
}
