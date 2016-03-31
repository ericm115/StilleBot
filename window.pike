//GTK utility functions/classes lifted straight from Gypsum


//Usage: gtksignal(some_object,"some_signal",handler,arg,arg,arg) --> save that object.
//Equivalent to some_object->signal_connect("some_signal",handler,arg,arg,arg)
//When it expires, the signal is removed. obj should be a GTK2.G.Object or similar.
class gtksignal(object obj)
{
	int signal_id;
	void create(mixed ... args) {if (obj) signal_id=obj->signal_connect(@args);}
	void destroy() {if (obj && signal_id) obj->signal_disconnect(signal_id);}
}

class MessageBox
{
	inherit GTK2.MessageDialog;
	function callback;

	//flags: Normally 0. type: 0 for info, else GTK2.MESSAGE_ERROR or similar. buttons: GTK2.BUTTONS_OK etc.
	void create(int flags,int type,int buttons,string message,GTK2.Window parent,function|void cb,mixed|void cb_arg)
	{
		callback=cb;
		#if constant(COMPAT_MSGDLG)
		//There's some sort of issue in older Pikes (7.8 only) regarding the parent.
		//TODO: Hunt down what it was and put a better note here.
		::create(flags,type,buttons,message);
		#else
		::create(flags,type,buttons,message,parent);
		#endif
		signal_connect("response",response,cb_arg);
		show();
	}

	void response(object self,int button,mixed cb_arg)
	{
		self->destroy();
		if (callback) callback(button,cb_arg);
	}
}

//A message box that calls its callback only if the user chooses OK. If you need to do cleanup
//on Cancel, use MessageBox above.
class confirm
{
	inherit MessageBox;
	void create(int flags,string message,GTK2.Window parent,function cb,mixed|void cb_arg)
	{
		::create(flags,GTK2.MESSAGE_WARNING,GTK2.BUTTONS_OK_CANCEL,message,parent,cb,cb_arg);
	}
	void response(object self,int button,mixed cb_arg)
	{
		self->destroy();
		if (callback && button==GTK2.RESPONSE_OK) callback(cb_arg);
	}
}

//Exactly the same as a GTK2.TextView but with additional methods for GTK2.Entry compatibility.
//Do not provide a buffer; create this with no args, and if you need access to the buffer, call
//obj->get_buffer() separately. NOTE: This does not automatically scroll (a GTK2.Entry does). If
//you need scrolling, place this inside a GTK2.ScrolledWindow.
class MultiLineEntryField
{
	#if constant(GTK2.SourceView)
	inherit GTK2.SourceView;
	#else
	inherit GTK2.TextView;
	#endif
	this_program set_text(mixed ... args)
	{
		object buf=get_buffer();
		buf->begin_user_action(); //Permit undo of the set_text operation
		buf->set_text(@args);
		buf->end_user_action();
		return this;
	}
	string get_text()
	{
		object buf=get_buffer();
		return buf->get_text(buf->get_start_iter(),buf->get_end_iter(),0);
	}
	this_program set_position(int pos)
	{
		object buf=get_buffer();
		buf->place_cursor(buf->get_iter_at_offset(pos));
		return this;
	}
	int get_position()
	{
		object buf=get_buffer();
		return buf->get_iter_at_mark(buf->get_insert())->get_offset();
	}
	this_program set_visibility(int state)
	{
		#if !constant(COMPAT_NOPASSWD)
		object buf=get_buffer();
		(state?buf->remove_tag_by_name:buf->apply_tag_by_name)("password", buf->get_start_iter(), buf->get_end_iter());
		#endif
		return this;
	}
}

//GTK2.ComboBox designed for text strings. Has set_text() and get_text() methods.
//Should be able to be used like an Entry.
class SelectBox(array(string) strings)
{
	inherit GTK2.ComboBox;
	void create() {::create(""); foreach (strings,string str) append_text(str);}
	this_program set_text(string txt)
	{
		set_active(search(strings,txt));
		return this;
	}
	string get_text() //Like get_active_text() but will return 0 (not "") if nothing's selected (may not strictly be necessary, but it's consistent with entry fields and such)
	{
		int idx=get_active();
		return (idx>=0 && idx<sizeof(strings)) && strings[idx];
	}
	void set_strings(array(string) newstrings)
	{
		foreach (strings,string str) remove_text(0);
		foreach (strings=newstrings,string str) append_text(str);
	}
}

//Advisory note that this widget should be packed without the GTK2.Expand|GTK2.Fill options
//As of Pike 8.0.2, this could safely be done with wid->set_data(), but it's not
//safe to call get_data() with a keyword that hasn't been set (it'll segfault older Pikes).
//So this works with a multiset instead. Once Pike 7.8 support can be dropped, switch to
//get_data to ensure that loose references are never kept.
multiset(GTK2.Widget) _noexpand=(<>);
GTK2.Widget noex(GTK2.Widget wid) {_noexpand[wid]=1; return wid;}

/** Create a GTK2.Table based on a 2D array of widgets
 * The contents will be laid out on the grid. Put a 0 in a cell to span
 * across multiple cells (the object preceding the 0 will span both cells).
 * Use noex(widget) to make a widget not expand (usually will want to do
 * this for a whole column). Shortcut: Labels can be included by simply
 * including a string - it will be turned into a label, expansion off, and
 * with options as set by the second parameter (if any).
 * A leading 0 on a line will be quietly ignored, not resulting in any
 * spanning. Recommended for unlabelled objects in a column of labels.
 */
GTK2.Table GTK2Table(array(array(string|GTK2.Widget)) contents,mapping|void label_opts)
{
	if (!label_opts) label_opts=([]);
	GTK2.Table tb=GTK2.Table(sizeof(contents[0]),sizeof(contents),0);
	foreach (contents;int y;array(string|GTK2.Widget) row) foreach (row;int x;string|GTK2.Widget obj) if (obj)
	{
		int opt=0;
		if (stringp(obj)) {obj=GTK2.Label(label_opts+(["label":obj])); opt=GTK2.Fill;}
		else if (_noexpand[obj]) _noexpand[obj]=0; //Remove it from the set so we don't hang onto references to stuff we don't need
		else opt=GTK2.Fill|GTK2.Expand;
		int xend=x+1; while (xend<sizeof(row) && !row[xend]) ++xend; //Span cols by putting 0 after the element
		tb->attach(obj,x,xend,y,y+1,opt,opt,1,1);
	}
	return tb;
}

//Derivative of GTK2Table above, specific to a two-column layout. Takes a 1D array.
//This is the most normal way to lay out labelled objects - alternate string labels and objects, or use CheckButtons without labels.
//The labels will be right justified.
GTK2.Table two_column(array(string|GTK2.Widget) contents) {return GTK2Table(contents/2,(["xalign":1.0]));}

//End of generic GTK utility classes/functions

//Generic window handler. If a plugin inherits this, it will normally show the window on startup and
//keep it there, though other patterns are possible. For instance, the window might be hidden when
//there's nothing useful to show; although this can cause unnecessary flicker, and so should be kept
//to a minimum (don't show/hide/show/hide in rapid succession). Note that this (via a subclass)
//implements the core window, not just plugin windows, as there's no fundamental difference.
//Transient windows (eg popups etc) are best implemented with nested classes - see usage of configdlg
//('inherit configdlg') for the most common example of this.
class window
{
	constant provides="window";
	mapping(string:mixed) win=([]);
	constant is_subwindow=1; //Set to 0 to disable the taskbar/pager hinting

	//Replace this and call the original after assigning to win->mainwindow.
	void makewindow() {if (win->accelgroup) win->mainwindow->add_accel_group(win->accelgroup);}

	//Stock item creation: Close button. Calls closewindow(), same as clicking the cross does.
	GTK2.Button stock_close()
	{
		if (!win->accelgroup) win->accelgroup=GTK2.AccelGroup();
		return win->stock_close=GTK2.Button((["use-stock":1,"label":GTK2.STOCK_CLOSE]))
			->add_accelerator("clicked",win->accelgroup,0xFF1B,0,0); //Esc as a shortcut for Close
	}

	//Subclasses should call ::dosignals() and then append to to win->signals. This is the
	//only place where win->signals is reset. Note that it's perfectly legitimate to have
	//non-signals in the array; for future compatibility, ensure that everything is either
	//a gtksignal object or the integer 0, though as of 20150103 nothing depends on this.
	void dosignals()
	{
		//NOTE: This does *not* use += here - this is where we (re)initialize the array.
		win->signals=({
			gtksignal(win->mainwindow,"delete_event",closewindow),
			win->stock_close && gtksignal(win->stock_close,"clicked",closewindow),
		});
		collect_signals("sig_", win);
	}

	void collect_signals(string prefix, mapping(string:mixed) searchme,mixed|void arg)
	{
		foreach (indices(this),string key) if (has_prefix(key,prefix) && callablep(this[key]))
		{
			//Function names of format sig_x_y become a signal handler for win->x signal y.
			//(Note that classes are callable, so they can be used as signal handlers too.)
			//This may pose problems, as it's possible for x and y to have underscores in
			//them, so we scan along and find the shortest such name that exists in win[].
			//If there's none, ignore it. This can create ambiguities, but only in really
			//contrived situations, so I'm deciding not to care. :)
			array parts=(key/"_")[1..];
			int b4=(parts[0]=="b4"); if (b4) parts=parts[1..]; //sig_b4_some_object_some_signal will connect _before_ the normal action
			for (int i=0;i<sizeof(parts)-1;++i) if (mixed obj=searchme[parts[..i]*"_"])
			{
				if (objectp(obj) && callablep(obj->signal_connect))
				{
					win->signals+=({gtksignal(obj,parts[i+1..]*"_",this[key],arg,UNDEFINED,b4)});
					break;
				}
			}
		}
	}
	void create(string|void name)
	{
		if (name) sscanf(explode_path(name)[-1],"%s.pike",name);
		if (name) {if (G->G->windows[name]) win=G->G->windows[name]; else G->G->windows[name]=win;}
		win->self=this;
		if (!win->mainwindow) makewindow();
		if (is_subwindow) win->mainwindow->set_transient_for(win->_parentwindow || G->G->window->mainwindow);
		win->mainwindow->set_skip_taskbar_hint(is_subwindow)->set_skip_pager_hint(is_subwindow)->show_all();
		dosignals();
	}
	void showwindow()
	{
		if (!win->mainwindow) {makewindow(); dosignals();}
		win->mainwindow->set_no_show_all(0)->show_all();
	}
	int hidewindow()
	{
		win->mainwindow->hide();
		return 1; //Simplify anti-destruction as "return hidewindow()". Note that this can make updating tricky - be aware of this.
	}
	int closewindow()
	{
		win->mainwindow->destroy();
		return 1;
	}
}

//Subclass of window that handles save/load of position automatically.
class movablewindow
{
	inherit window;
	constant pos_key=0; //(string) Set this to the persist[] key in which to store and from which to retrieve the window pos
	constant load_size=0; //If set to 1, will attempt to load the size as well as position. (It'll always be saved.)
	constant provides=0;

	void makewindow()
	{
		if (array pos=persist[pos_key])
		{
			if (sizeof(pos)>3 && load_size) win->mainwindow->set_default_size(pos[2],pos[3]);
			win->x=1; call_out(lambda() {m_delete(win,"x");},1);
			win->mainwindow->move(pos[0],pos[1]);
		}
		::makewindow();
	}

	void sig_b4_mainwindow_configure_event()
	{
		if (!has_index(win,"x")) call_out(savepos,0.1);
		mapping pos=win->mainwindow->get_position(); win->x=pos->x; win->y=pos->y;
	}

	void savepos()
	{
		if (!pos_key) {werror("%% Assertion failed: Cannot save position without pos_key set!"); return;} //Shouldn't happen.
		mapping sz=win->mainwindow->get_size();
		persist[pos_key]=({m_delete(win,"x"),m_delete(win,"y"),sz->width,sz->height});
	}

	void dosignals()
	{
		::dosignals();
	}
}

//Base class for a configuration dialog. Permits the setup of anything where you
//have a list of keyworded items, can create/retrieve/update/delete them by keyword.
//It may be worth breaking out some of this code into a dedicated ListBox class
//for future reuse. Currently I don't actually need that for Gypsum, but it'd
//make a nice utility class for other programs.
class configdlg
{
	inherit window;
	//Provide me...
	mapping(string:mixed) windowprops=(["title":"Configure"]);
	mapping(string:mapping(string:mixed)) items; //Will never be rebound. Will generally want to be an alias for a better-named mapping, or something out of persist[] (and see persist_key)
	void save_content(mapping(string:mixed) info) { } //Retrieve content from the window and put it in the mapping.
	void load_content(mapping(string:mixed) info) { } //Store information from info into the window
	void delete_content(string kwd,mapping(string:mixed) info) { } //Delete the thing with the given keyword.
	string actionbtn; //(DEPRECATED) If set, a special "action button" will be included, otherwise not. This is its caption.
	void action_callback() { } //(DEPRECATED) Callback when the action button is clicked (provide if actionbtn is set)
	constant allow_new=1; //Set to 0 to remove the -- New -- entry; if omitted, -- New -- will be present and entries can be created.
	constant allow_delete=1; //Set to 0 to disable the Delete button (it'll always be visible though)
	constant allow_rename=1; //Set to 0 to ignore changes to keywords
	constant strings=({ }); //Simple string bindings - see plugins/README
	constant ints=({ }); //Simple integer bindings, ditto
	constant bools=({ }); //Simple boolean bindings (to CheckButtons), ditto
	constant labels=({ }); //Labels for the above
	/* ADVISORY and under test: Instead of using all of the above four, use a single list of
	tokens which gets parsed out to provide keyword, label, and type.
	constant elements=({"kwd:Keyword", "name:Name", "?state:State of Being", "#value:Value","+descr:Description"});
	If the colon is omitted, the keyword will be the first word of the lowercased name, so this is equivalent:
	constant elements=({"kwd:Keyword", "Name", "?State of Being", "#Value", "+descr:Description"});
	In most cases, this and persist_key will be all you need to set.
	TODO: Figure out a way to allow a SelectBox. Or maybe some kind of marker "custom thing goes here"?
	*/
	constant elements=({ });
	constant persist_key=0; //(string) Set this to the persist[] key to load items[] from; if set, persist will be saved after edits.
	constant descr_key=0; //(string) Set this to a key inside the info mapping to populate with descriptions.
	//... end provide me.

	void create() {if (persist_key && !items) items=persist->setdefault(persist_key,([])); ::create();} //Pass on no args to the window constructor - all configdlgs are independent

	//Return the keyword of the selected item, or 0 if none (or new) is selected
	string selecteditem()
	{
		[object iter,object store]=win->sel->get_selected();
		string kwd=iter && store->get_value(iter,0);
		return (kwd!="-- New --") && kwd; //TODO: Recognize the "New" entry by something other than its text
	}

	void sig_pb_save_clicked()
	{
		string oldkwd=selecteditem();
		string newkwd=allow_rename?win->kwd->get_text():oldkwd;
		if (newkwd=="") return; //Blank keywords currently disallowed
		if (newkwd=="-- New --") return; //Since selecteditem() currently depends on "-- New --" being the 'New' entry, don't let it be used anywhere else.
		mapping info;
		if (allow_rename) info=m_delete(items,oldkwd); else info=items[oldkwd];
		if (!info)
			if (allow_new) info=([]); else return;
		if (allow_rename) items[newkwd]=info;
		foreach (win->real_strings,string key) info[key]=win[key]->get_text();
		foreach (win->real_ints,string key) info[key]=(int)win[key]->get_text();
		foreach (win->real_bools,string key) info[key]=(int)win[key]->get_active();
		save_content(info);
		if (persist_key) persist->save();
		[object iter,object store]=win->sel->get_selected();
		if (newkwd!=oldkwd)
		{
			if (!oldkwd) win->sel->select_iter(iter=store->insert_before(win->new_iter));
			store->set_value(iter,0,newkwd);
		}
		if (descr_key && info[descr_key]) store->set_value(iter,1,info[descr_key]);
	}

	void sig_pb_delete_clicked()
	{
		if (!allow_delete) return; //The button will be insensitive anyway, but check just to be sure.
		[object iter,object store]=win->sel->get_selected();
		string kwd=iter && store->get_value(iter,0);
		if (!kwd) return;
		store->remove(iter);
		foreach (win->real_strings+win->real_ints,string key) win[key]->set_text("");
		foreach (win->real_bools,string key) win[key]->set_active(0);
		delete_content(kwd,m_delete(items,kwd));
		if (persist_key) persist->save();
	}

	void sig_sel_changed()
	{
		string kwd=selecteditem();
		mapping info=items[kwd] || ([]);
		if (win->kwd) win->kwd->set_text(kwd || "");
		foreach (win->real_strings,string key) win[key]->set_text((string)(info[key] || ""));
		foreach (win->real_ints,string key) win[key]->set_text((string)info[key]);
		foreach (win->real_bools,string key) win[key]->set_active((int)info[key]);
		load_content(info);
	}

	void makewindow()
	{
		win->real_strings = win->real_ints = win->real_bools = ({ });
		object ls=GTK2.ListStore(({"string","string"}));
		//TODO: Break out the list box code into a separate object - it'd be useful eg for zoneinfo.pike.
		foreach (sort(indices(items)),string kwd)
		{
			object iter=ls->append();
			ls->set_value(iter,0,kwd);
			if (string descr=descr_key && items[kwd][descr_key]) ls->set_value(iter,1,descr);
		}
		if (allow_new) ls->set_value(win->new_iter=ls->append(),0,"-- New --");
		win->mainwindow=GTK2.Window(windowprops)
			->add(GTK2.Vbox(0,10)
				->add(GTK2.Hbox(0,5)
					->add(win->list=GTK2.TreeView(ls) //All I want is a listbox. This feels like *such* overkill. Oh well.
						->append_column(GTK2.TreeViewColumn("Item",GTK2.CellRendererText(),"text",0))
						->append_column(GTK2.TreeViewColumn("",GTK2.CellRendererText(),"text",1))
					)
					->add(GTK2.Vbox(0,0)
						->add(make_content())
						->pack_end(
							(actionbtn?GTK2.HbuttonBox()
							->add(win->pb_action=GTK2.Button((["label":actionbtn,"use-underline":1])))
							:GTK2.HbuttonBox())
							->add(win->pb_save=GTK2.Button((["label":"_Save","use-underline":1])))
							->add(win->pb_delete=GTK2.Button((["label":"_Delete","use-underline":1,"sensitive":allow_delete])))
						,0,0,0)
					)
				)
				->add(win->buttonbox=GTK2.HbuttonBox()->pack_end(stock_close(),0,0,0))
			);
		win->sel=win->list->get_selection(); win->sel->select_iter(win->new_iter||ls->get_iter_first()); sig_sel_changed();
		::makewindow();
	}

	//Generate a widget collection from either the constant or migration mode
	array(string|GTK2.Widget) collect_widgets(array|void elem)
	{
		array objects = ({ });
		elem = elem || elements; if (!sizeof(elem)) elem = migrate_elements();
		foreach (elem, string element)
		{
			sscanf(element, "%1[?#+']%s", string type, element);
			sscanf(element, "%s:%s", string name, string lbl);
			if (!lbl) sscanf(lower_case(lbl = element)+" ", "%s ", name);
			switch (type)
			{
				case "?": //Boolean
					win->real_bools += ({name});
					objects += ({0,win[name]=noex(GTK2.CheckButton(lbl))});
					break;
				case "#": //Integer
					win->real_ints += ({name});
					objects += ({lbl, win[name]=noex(GTK2.Entry())});
					break;
				case 0: //String
					win->real_strings += ({name});
					objects += ({lbl, win[name]=noex(GTK2.Entry())});
					break;
				case "+": //Multi-line text
					win->real_strings += ({name});
					objects += ({GTK2.Frame(lbl)->add(
						win[name]=MultiLineEntryField()->set_wrap_mode(GTK2.WRAP_WORD_CHAR)->set_size_request(225,70)
					),0});
					break;
				case "'": //Descriptive text
					objects += ({noex(GTK2.Label(lbl)->set_line_wrap(1)), 0});
					break;
			}
		}
		win->real_strings -= ({"kwd"});
		return objects;
	}

	//Iterates over labels, applying them to controls in this order:
	//1) win->kwd, if allow_rename is not zeroed
	//2) strings, creating Entry()
	//3) ints, ditto
	//4) bools, creating CheckButton()
	//5) strings, if marked to create MultiLineEntryField()
	//6) Descriptive text underneath
	//Not yet supported: Anything custom, eg insertion or reordering;
	//any other widget types eg SelectBox.
	array(string) migrate_elements()
	{
		array stuff = ({ });
		array atend = ({ });
		Iterator lbl = get_iterator(labels);
		if (!lbl) return stuff;
		if (allow_rename)
		{
			stuff += ({"kwd:"+lbl->value()});
			if (!lbl->next()) return stuff;
		}
		foreach (strings+ints, string name)
		{
			string desc=lbl->value();
			if (desc[0]=='\n') //Hack: Multiline fields get shoved to the end. Hack is not needed if elements[] is used instead - this is recommended.
				atend += ({sprintf("+%s:%s",name,desc[1..])});
			else
				stuff += ({sprintf("%s:%s",name,desc)});
			if (!lbl->next()) return stuff+atend;
		}
		foreach (bools, string name)
		{
			stuff += ({sprintf("?%s:%s",name,lbl->value())});
			if (!lbl->next()) return stuff+atend;
		}
		stuff += atend; //Now grab any multiline string fields
		//Finally, consume the remaining entries making text. There'll most
		//likely be zero or one of them.
		foreach (lbl;;string text)
			stuff += ({"'"+text});
		return stuff;
	}

	//Create and return a widget (most likely a layout widget) representing all the custom content.
	//If allow_rename (see below), this must assign to win->kwd a GTK2.Entry for editing the keyword;
	//otherwise, win->kwd is optional (it may be present and read-only (and ignored on save), or
	//it may be a GTK2.Label, or it may be omitted altogether).
	//By default, makes a two_column based on collect_widgets. It's easy to override this to add some
	//additional widgets before or after the ones collect_widgets creates.
	GTK2.Widget make_content()
	{
		return two_column(collect_widgets());
	}

	//Attempt to select the given keyword - returns 1 if found, 0 if not
	int select_keyword(string kwd)
	{
		object ls=win->list->get_model();
		object iter=ls->get_iter_first();
		do
		{
			if (ls->get_value(iter,0)==kwd)
			{
				win->sel->select_iter(iter); sig_sel_changed();
				return 1;
			}
		} while (ls->iter_next(iter));
		return 0;
	}

	void dosignals()
	{
		::dosignals();
		if (actionbtn) win->signals+=({gtksignal(win->pb_action,"clicked",action_callback)});
	}
}
//End code lifted from Gypsum

//All GUI code starts with this file, which also constructs the primary window.
//Normally, the "inherit configdlg" line would be at top level, but in this case,
//the above class definitions have to happen before this one.
class mainwindow
{
	inherit configdlg;
	mapping(string:mixed) windowprops=(["title": "StilleBot"]);
	constant elements=({"kwd:Channel", "?allcmds:All commands active", "+notes:Notes"});
	constant persist_key = "channels";
	mapping(string:mapping(string:mixed)) items = persist->setdefault(persist_key,([])); //Necessary because we bypass ::create()
	constant is_subwindow = 0;
	void create() {window::create("mainwindow");} //Bypass the configdlg constructor which would pass on no args

	void makewindow()
	{
		::makewindow();
		//Remove the close button - we don't need it.
		//(You can still click the cross or press Alt-F4 or anything else.)
		win->buttonbox->remove(win->stock_close);
		destruct(win->stock_close);
	}

	void save_content(mapping(string:mixed) info)
	{
		string kwd = win->kwd->get_text();
		if (!G->G->irc->channels["#"+kwd])
		{
			write("%%% Joining #"+kwd+"\n");
			G->G->irc->join_channel("#"+kwd);
		}
	}
	void delete_content(string kwd,mapping(string:mixed) info)
	{
		write("%%% Parting #"+kwd+"\n");
		G->G->irc->part_channel("#"+kwd);
	}

	void closewindow() {exit(0);}
}

void create(string name)
{
	add_constant("window", window);
	if (!G->G->windows)
	{
		//First time initialization
		G->G->windows = ([]);
		G->G->argv = GTK2.setup_gtk(G->G->argv);
	}
	mainwindow();
}
