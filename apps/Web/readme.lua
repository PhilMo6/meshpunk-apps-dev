-- Help page for the Web browser (loaded sandboxed by lib/helpdocs).
local caps = ...

local body = [[
A reader-class web browser: real pages
over HTTP and HTTPS (verified TLS),
rendered as clean text that appears
while the page still downloads. Forms
work (search boxes, buttons, dropdowns),
section links jump within the page, and
tapping an [image] opens it full screen
(tap again to close). No JavaScript, no
CSS — sites that need them won't work;
article pages, wikis, docs and the small
web do.

THE BAR
The address bar lives on its own layer:
press m or tap the thin status strip at
the top to summon it, and the same tap
(or its v button) puts it away. It also
closes itself whenever a page loads. The
field spans the full screen; below it:
< > back/forward, Go, H home, v hide;
second row: Book bookmarks the page,
Menu, x closes the app. Everything works
without a keyboard.

THE MENU
Find in page opens the search strip (the
f or / key does the same). History lists
the pages you have visited, newest first,
and Bookmarks lists the ones you kept —
either way, tap an entry to open it
without going home first.

Reader mode sends the page to FrogFind's
reader, which strips it to the article
text — useful when a site renders badly
here. Note it fetches through their
server over plain HTTP, so that one is
not private, and it cannot handle every
site (Wikipedia is one it refuses).
Clear cookies empties the session jar
without closing the app, and Clear
history empties the visited list. The
menu scrolls — drag it if an entry sits
below the edge.

Type a URL and press Go. Anything that
doesn't look like a URL is searched on
your chosen engine — the home view shows
which one and lets you change it
(Marginalia, Wiby or FrogFind).

BACK, HOME AND BOOKMARKS
Back and forward walk this session's
trail, and the home view counts as a
page on it — H goes home, back returns
to what you were reading. The home view
lists your bookmarks and your recently
visited pages as tappable lines; both
survive restarts. Book adds the page you
are reading; Book again removes it.

READING AND FORMS
Links are underlined; the focused link
is brighter. Tap a link block to open
it — a block with several links opens a
chooser. Form fields are real inputs:
tap one to type into it, then press its
button to submit. f opens find-in-page
(the matching block flashes).

Pages larger than 512 KB are truncated,
and a note appears at the end.
]]

if caps.keyboard then
    body = body .. [[

KEYS
m           show the address bar
arrows      scroll the page / move focus
n, space    next link        p  previous
Enter       open the focused link
q, Bksp     back             Home/End  jump
b           bookmark         h  home view
f or /      find in page     r  reader mode
]]
end

-- An app page's title/section/order are set by the registry, not here
-- (lib/helpdocs).
return { body = body }
