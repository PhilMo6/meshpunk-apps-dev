local caps = ...

local body = [[
PICO-8 fantasy console, using the fake08 core. It runs carts made for PICO-8; it is not the official PICO-8 and includes no carts.

CARTS
.p8 and .p8.png cart files, in /p8carts on the SD card or in the PICO-8 app folder. A plain .png is not a cart - the double extension is PICO-8's own cart-image format.

SETTINGS
- Game folder: any folder on the SD card or in internal storage; its carts join the list alongside those in /p8carts and the app folder.

BBS
The BBS button lists the carts people share on the PICO-8 BBS at lexaloffle.com: Featured, Releases, Work in progress, Jam and the other sections, or a search. Pick a cart to see its cart image, author and BBS page, then Download - the cart is saved to /p8carts on the SD card and joins your cart list, ready to Play. Description loads the author's post from the BBS: the description, tags, stars and license. Needs WiFi and an SD card. Carts posted to the BBS belong to their authors.
]]

if caps.trackball then
    body = body .. [[

DEFAULT KEYS
D-pad - W A S D, or the trackball
O - Z, or trackball click
X - X, or Space
Pause - Enter, or P
]]
else
    body = body .. [[

DEFAULT KEYS]] .. (caps.keyboard and "" or " (USB keyboard)") .. [[

D-pad - W A S D
O - Z
X - X, or Space
Pause - Enter, or P
]]
end

body = body .. [[

O and X are what PICO-8 calls its two buttons. Change any of these in Controls.
]]

if not caps.keyboard then
    body = body .. [[

On this device you play on the on-screen pad or with a USB gamepad. The Touch button opens the pad's layout editor, and the Games > Gamepad app maps a gamepad's buttons. Hold the on-screen QUIT button for about a second to exit.]]
else
    body = body .. [[

Hold Alt and Backspace for about 1.5 seconds to quit back to the launcher.]]
end

return { body = body }
