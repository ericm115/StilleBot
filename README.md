StilleBot handles Twitch chat and some other functionality. It's named after
Oberstille, because he joked around with me about names right at the time when
I needed to figure out a name. (On such thin threads...)

Installation information and tips for Windows and for Mac OS X can be found in
README.WIN and README.OSX respectively. Installation on Linux depends on your
distribution; search your package manager for "pike" or see the above web site.
Compiling Pike from source is best, if you're comfortable with that; Pike 8.1
has a number of improvements over Pike 7.8.

For a list of available in-chat commands, check [these pages](https://rosuav.github.io/StilleBot/commands/).


COMPATIBILITY NOTE: As of 20181221, the module protocol for command handlers
has been changed. Instead of passing around "object person", handlers are given
"mapping person", and will contain slightly different information. Other than
person->nick and person->user, nothing is guaranteed; check your modules and
check for anything that could be broken by this. It is recommended to switch
to using either person->uid (for identifying users) or person->displayname
(for addressing users).

Enabling SSL (https) for the web configuration pages requires some setup
work. See [instructions](SSL).


License: MIT

Copyright (c) 2016-2019, Chris Angelico

Permission is hereby granted, free of charge, to any person obtaining a copy of 
this software and associated documentation files (the "Software"), to deal in 
the Software without restriction, including without limitation the rights to 
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
of the Software, and to permit persons to whom the Software is furnished to do 
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all 
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
SOFTWARE.
