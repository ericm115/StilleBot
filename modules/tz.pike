inherit command;

mapping timezones;

constant days_of_week = ({"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"});

string timezone_info(string tz)
{
	if (!tz || tz=="") return "Regions are: " + sort(indices(timezones))*", " + ". You can also add a weekday and time, eg '!tz America/Los_Angeles Thu 10:00'.";
	sscanf(tz, "%s %s", tz, string time);
	mapping|string region = timezones;
	foreach (lower_case(tz)/"/", string part) if (!mappingp(region=region[part])) break;
	if (undefinedp(region))
		return "Unknown region "+tz+" - use '!tz' to list";
	if (mappingp(region))
		return "Locations in region "+tz+": "+sort(indices(region))*", ";
	if (catch {
		if (!time) return region+" - "+Calendar.Gregorian.Second()->set_timezone(region)->format_time();
		string ret = "";
		foreach (({({region, "America/Los_Angeles", "%s %s in your time is %s %s in Christine's. "}),
			({"America/Los_Angeles", region, "%s %s in Christine's time is %s %s in yours."})}),
			[string tzfrom, string tzto, string msg])
		{
			sscanf(time, "%s %s", string dayname, string time); dayname = lower_case(dayname);
			int dow = -1;
			foreach (days_of_week; int idx; string d) if (has_prefix(lower_case(d), dayname)) dow = idx;
			Calendar.Gregorian.Day day = Calendar.Gregorian.Day()->set_timezone(tzfrom);
			sscanf(time, "%d:%d%s", int hr, int min, string ampm); if ((<"PM","pm">)[ampm]) hr+=12;
			if (!hr) hr = (int)time;
			Calendar.Gregorian.Second tm = day->second(3600*hr+60*min);
			if (int diff=hr-tm->hour_no()) tm=tm->add(3600*diff); //If DST switch happened, adjust time
			if (int diff=min-tm->minute_no()) tm=tm->add(60*diff);
			if (int diff=0-tm->second_no()) tm=tm->add(60*diff); //As above but since sec will always be zero, hard-code it.
			tm = tm->set_timezone(tzto);
			int daydiff = 0;
			if (tm->day() > day) daydiff = 1;
			else if (tm->day() < day) daydiff = -1;
			ret += sprintf(msg, days_of_week[dow], time, days_of_week[(dow+daydiff) % 7], tm->nice_print());
		}
		return ret;
	}) return "Unable to figure out the time in that location, sorry.";
}

string process(object channel, object person, string param)
{
	return "@$$: " + timezone_info(param);
}

void create(string name)
{
	timezones = ([]);
	foreach (sort(Calendar.TZnames.zonenames()), string zone)
	{
		array(string) parts = lower_case(zone)/"/";
		mapping tz = timezones;
		foreach (parts[..<1], string region)
			if (!tz[region]) tz = tz[region] = ([]);
			else tz = tz[region];
		tz[parts[-1]] = zone;
	}
	::create(name);
}
