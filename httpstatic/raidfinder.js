import choc, {set_content} from "https://rosuav.github.io/shed/chocfactory.js";
const {DIV, IMG, P, UL, LI} = choc;

const sortfunc = {
	Viewers: (s1, s2) => s1.viewers - s2.viewers,
	Category: (s1, s2) => s1.game.localeCompare(s2.game),
	Uptime: (s1, s2) => new Date(s2.created_at) - new Date(s1.created_at),
}

on("click", "#sort li", e => {
	const pred = sortfunc[e.match.innerText];
	if (!pred) {console.error("No predicate function for " + e.match.innerText); return;}
	follows.sort(pred);
	follows.forEach((stream, idx) => stream.element.style.order = idx);
});

function uptime(startdate) {
	const time = Math.floor((new Date() - new Date(startdate)) / 1000);
	if (time < 60) return time + " seconds";
	const hh = Math.floor((time / 3600) % 24);
	const mm = ("0" + Math.floor((time / 60) % 60)).slice(-2);
	const ss = ("0" + Math.floor(time % 60)).slice(-2);
	let ret = mm + ":" + ss;
	if (time >= 3600) ret = hh + ":" + ret;
	if (time >= 86400) ret = Math.floor(time / 86400) + "days, " + ret;
	return ret;
}

console.log(follows);
function build_follow_list() {
	set_content("#streams", follows.map(stream => stream.element = DIV([
		IMG({src: stream.preview.medium}),
		UL([
			LI(stream.channel.status),
			LI(stream.channel.display_name),
			LI(stream.game),
			LI("Uptime " + uptime(stream.created_at) + ", " + stream.viewers + " viewers"),
		]),
	])));
}
build_follow_list();
