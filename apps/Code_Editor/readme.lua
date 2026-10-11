return { body = [[
An on-device Lua editor, for writing and fixing scripts without a PC.

Open file browses the drives - internal storage, the SD card and a USB drive alike - and opens the file you tap. New file asks for a folder first, then a name; a name without an extension gets .lua.

In the editor, Sav writes the file, View shows it read-only, and < goes back to the start page. Run saves and executes the file you are editing: a file that builds an app takes over the screen, and an error shows a Runtime Error page with the message, so you can go back, fix it and run again.

This is how you can write an app on the device itself: an app is a folder with a main.lua in it, under lua/apps on either drive. The launcher picks up new folders when you leave the editor with Home.]] }
