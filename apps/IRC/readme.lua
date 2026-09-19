-- Help page for the IRC client (loaded sandboxed by lib/helpdocs).
local caps = ...

local body = [[
A full IRC client: several networks at
once over TLS, channels and private
chats, and it keeps receiving while you
use other apps, so a mention still
reaches you.

NETWORKS
Menu > Add network. Host and nick are
the only fields you must fill; the port
defaults to 6697 with TLS on. The home
screen lists your networks - tap one to
see its channels, with Connect next to
its Menu.

To log in, set auth to sasl and give the
account and password, or put your
password in the server password field.
Anything in perform is sent after
connecting, one command per line
separated by semicolons, which is where
a NickServ line goes.

CERTIFICATES
TLS is checked against the built-in
authority list. For a server using its
own certificate, set verify to pin: the
first connect stops with the certificate
on screen, and Trust pins it. From then
on that network refuses any other
certificate, and a later "certificate
changed" means exactly that.

CHANNELS
Join from the network Menu, or open
Channel list to browse what the server
has - it keeps the 500 largest, and its
Menu filters them or sets a minimum
size. Tap a channel there to join.

Channels you join are remembered and
rejoined every time you connect, even
after the app has been closed. Close
buffer is how you leave one for good.

CHAT
Hold a message for Reply, Copy text,
Query and Whois. Your own lines and
notices offer Copy only.

The chat Menu has the member list,
channel info (topic, modes, bans),
Paste, this chat's notification mode,
Clear and Close buffer. The wide button
shows the topic - tap it for the whole
thing. While you are scrolled up it
turns into a count of new lines instead;
tap to jump to the bottom.

Where the server offers history, older
messages load as you scroll to the top,
and they keep the time they were
actually sent.

Tap a member for Mention, Query and
Whois. If you hold channel operator
there is also Channel ops: give or take
ops and voice, kick, ban and kick+ban.

NOTIFICATIONS
Each chat has its own mode in its Menu -
Off, Mentions or All. Channels start at
mentions, private chats at all. Settings
holds the rest: connection, login and
certificate alerts.

BACKGROUND AND MEMORY
Menu > Run in background keeps the
connections up while you do something
else. Leaving by the home chord quits
IRC properly and sends QUIT. Standby
ends the session, and waking reconnects.

Nothing is written to disk, so messages
live in memory and Settings is the
budget: lines kept per channel and per
private chat, the raw log size, and how
many channels and private chats each
network may have. At a limit, new ones
are refused until you close one. With
Background memory on low, the buffers
shrink while another app is in front.

COMMANDS
The input takes commands as well as
text. /help lists them all; the common
ones are:
/join - join a channel
/part - leave, /close - leave for good
/msg - message a nick
/query - open a private chat
/me - an action
/topic - read or set the topic
/whois - who someone is
/list - browse channels
/op /deop /voice /ban /kick - operator
/quote - send a raw line
]]

if caps.keyboard then
    body = body .. [[

KEYS
Enter       send the line
Alt+Bksp    quit IRC (sends QUIT)
]]
end

-- An app page's title/section/order are set by the registry, not here
-- (lib/helpdocs).
return { body = body }
