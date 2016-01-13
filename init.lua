-- Seed the RNG
math.randomseed( os.time() )

-- Capture the hostname so we can make this config behave differently across my Macs
hostname = hs.host.localizedName()

-- Ensure the IPC command line client is available
hs.ipc.cliInstall()

-- Watchers and other useful objects
local configFileWatcher = nil
local wifiWatcher = nil
local screenWatcher = nil
local usbWatcher = nil
local caffeinateWatcher = nil

local mouseCircle = nil
local mouseCircleTimer = nil

local statusletTimer = nil
local firewallStatusText = nil
local firewallStatusDot = nil

-- Define some keyboard modifier variables
-- (note: capslock is bound to cmd+alt+ctrl via seil and Karabiner)
local capslock = {'cmd', 'alt', 'ctrl'}
local capslockshift = {'shift', 'cmd', 'alt', 'ctrl'}

-- Define monitor names for layout purposes
local display_laptop = "Color LCD"
local display_monitor = "ASUS PB278"

-- Defines for wifi watcher
local homeSSID = "sliderbase-5G"
local homeSSIDBackup = "sliderbase"
local lastSSID = hs.wifi.currentNetwork()

-- Defines for screen watcher
local lastNumberOfScreen = #hs.screen.allScreens()

-- Defines for window grid
hs.grid.GRIDWIDTH = 4
hs.grid.GRIDHEIGHT = 4
hs.grid.MARGINX = 0
hs.grid.MARGINY = 0

-- Defines for window maximize toggler
local frameCache = {}

-- Define window layouts
--    Format reminder:
--      {"app name", "window name", "display name", "unitrect", "framerect, "fullframerect"}
local internal_display = {
    {"Slack",          nil,          display_laptop, hs.layout.maximized, nil, nil},
    {"iTerm",          nil,          display_laptop, hs.layout.left30,    nil, nil},
    {"Google Chrome",  nil,          display_laptop, hs.layout.maximized, nil, nil},
    {hs.application.applicationsForBundleID("com.apple.Safari")[1],       nil, display_laptop, hs.layout.maximized, nil, nil},
    {"Messages",       nil,          display_laptop, hs.layout.maximized, nil, nil},
    {"Sublime Text",   nil,          display_laptop, hs.layout.maximized, nil, nil}
}

local dual_display = {
  {"Slack", nil, display_monitor, nil, nil, nil}
}

-- Helper functions

-- Replace Caffeine.app with 16 lines of Lua :D
local caffeine = hs.menubar.new()

function setCaffeineDisplay(state)
  local result
  if state then
    result = caffeine:setIcon("caffeine-on.pdf")
  else
    result = caffeine:setIcon("caffeine-off.pdf")
  end
end

function caffeineClicked()
  setCaffeineDisplay(hs.caffeinate.toggle("displayIdle"))
end

if caffeine then
  caffeine:setClickCallback(caffeineClicked)
  setCaffeineDisplay(hs.caffeinate.get("displayIdle"))
end

-- Replace HiddenMe.app with 31 lines of Lua
local hiddenMe = hs.menubar.new()

function getHiddenMeStatus()
  local handle = io.popen('defaults read com.apple.finder CreateDesktop')
  local result = handle:read('*a')
  handle:close()
  if (result == 'true\n') then
    return true
  else
    return false
  end
end

function setHiddenMeDisplay(state)
  local result
  if state then
    result = hiddenMe:setIcon("hiddenMe-off.pdf")
  else
    result = hiddenMe:setIcon("hiddenMe-on.pdf")
  end
end

function hiddenMeClicked()
  if getHiddenMeStatus() then
    os.execute('defaults write com.apple.finder CreateDesktop false; killall Finder')
  else
    os.execute('defaults write com.apple.finder CreateDesktop true; killall Finder')
  end
  setHiddenMeDisplay(getHiddenMeStatus())
end

if hiddenMe then
  hiddenMe:setClickCallback(hiddenMeClicked)
  setHiddenMeDisplay(getHiddenMeStatus())
end

-- sleep watcher...
local sleepModule = {}
sleepModule._loopSleepWatcher = hs.caffeinate.watcher.new(function(event)
  if (event == hs.caffeinate.watcher.systemWillSleep) then
    os.execute("networksetup -setairportpower en0 off")
  end
  if (event == hs.caffeinate.watcher.systemDidWake) then
    os.execute("networksetup -setairportpower en0 on")
  end
end):start()

-- Toggle an application between being the frontmost app, and being hidden
function toggle_application(_app)
    local app = hs.appfinder.appFromName(_app)
    if not app then
        -- FIXME: This should really launch _app
        return
    end
    local mainwin = app:mainWindow()
    if mainwin then
        if mainwin == hs.window.focusedWindow() then
            mainwin:application():hide()
        else
            mainwin:application():activate(true)
            mainwin:application():unhide()
            mainwin:focus()
        end
    end
end

-- Toggle a window between its normal size, and being maximized
function toggle_window_maximized()
    local win = hs.window.focusedWindow()
    if frameCache[win:id()] then
        win:setFrame(frameCache[win:id()])
        frameCache[win:id()] = nil
    else
        frameCache[win:id()] = win:frame()
        win:maximize()
    end
end

-- Callback function for application events
function applicationWatcher(appName, eventType, appObject)
  if (eventType == hs.application.watcher.activated) then
    if (appName == "Finder") then
      -- bring all finder windows forward when one gets activated
      appObject:selectMenuItem({"Window", "Bring All to Front"})
    end
  end
end

-- toggle display of dotfiles in Finder
function toggleDotFiles()
  local handle = io.popen('defaults read com.apple.finder AppleShowAllFiles')
  local result = handle:read('*a')
  handle:close()
  if (result == 'true\n') then
    os.execute('defaults write com.apple.finder AppleShowAllFiles false')
  else
    os.execute('defaults write com.apple.finder AppleShowAllFiles true')
  end
  os.execute('killall Finder')
  hs.application.launchOrFocus('Finder')
end

-- I always end up losing my mouse pointer, particularly if it's on a monitor full of terminals.
-- This draws a bright red circle around the pointer for a few seconds
function mouseHighlight()
    if mouseCircle then
        mouseCircle:delete()
        if mouseCircleTimer then
            mouseCircleTimer:stop()
        end
    end
    mousepoint = hs.mouse.getAbsolutePosition()
    mouseCircle = hs.drawing.circle(hs.geometry.rect(mousepoint.x-40, mousepoint.y-40, 80, 80))
    mouseCircle:setStrokeColor({["red"]=1,["blue"]=.65,["green"]=0.1,["alpha"]=1})
    mouseCircle:setFill(false)
    mouseCircle:setStrokeWidth(5)
    mouseCircle:bringToFront(true)
    mouseCircle:show()

    mouseCircleTimer = hs.timer.doAfter(2, function() mouseCircle:delete() end)
end

-- Callback function for wifi SSID change events
function ssidChangedCallback()
  newSSID = hs.wifi.currentNetwork()

  print("ssidChangedCallback: old:"..(lastSSID or "nil").." new:"..(newSSID or "nil"))
  if newSSID == homeSSID and lastSSID ~= homeSSID then
    -- We have gone from something that isn't my home wifi, to something that is
    home_arrived()
  elseif newSSID ~= homeSSID and lastSSID == homeSSID then
    -- We have gone from something that is my home wifi, to something that isn't
    home_departed()
  end

  lastSSID = newSSID
end

-- Perform tasks to configure system for my home wifi network
function home_arrived()
  hs.audiodevice.defaultOutputDevice():setVolume(33)

  -- Note: sudo commands will need to have been pre-configured in /etc/sudoers, for passwordless access, e.g.:
  -- rohn ALL=(root) NOPASSWD: /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall *
  os.execute("sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall off")

  hs.notify.new({
    title='Hammerspoon',
    informativeText='unmuted audio, disabled firewall'
    }):send()
end

function home_departed()
  hs.audiodevice.defaultOutputDevice():setVolume(0)
  os.execute("sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on")

  hs.notify.new({
    title='Hammerspoon',
    informativeText='muted audio, enabled firewall'
    }):send()
end

-- Create and start our callbacks
hs.application.watcher.new(applicationWatcher):start()
wifiWatcher = hs.wifi.watcher.new(ssidChangedCallback)
wifiWatcher:start()

-- make sure we have the right location settings
if hs.wifi.currentNetwork() == "sliderbase" or hs.wifi.currentNetwork() == "sliderbase-5G" then
  home_arrived()
else
  home_departed()
end

-- watch for a change in the config file and reload
-- Reload config
function reloadConfig(paths)
    doReload = false
    for _,file in pairs(paths) do
        if file:sub(-4) == ".lua" then
            print("A lua file changed, doing reload")
            doReload = true
        end
    end
    if not doReload then
        print("No lua file changed, skipping reload")
        return
    end

    hs.reload()
end

configFileWatcher = hs.pathwatcher.new(os.getenv("HOME") .. "/.hammerspoon/", reloadConfig)
configFileWatcher:start()

-------------------------------------------------

local Grid = require 'grid'

-- Hotkeys to resize windows absolutely
hs.hotkey.bind(capslock, 'f', toggle_window_maximized)
hs.hotkey.bind(capslock, 'r', function() hs.window.focusedWindow():toggleFullScreen() end)

-- Hotkeys to trigger defined layouts
hs.hotkey.bind(capslock, '1', function() hs.layout.apply(internal_display) end)
hs.hotkey.bind(capslock, '2', function() hs.layout.apply(dual_display) end)

-- Hotkeys to interact with the window grid
hs.hotkey.bind(capslock, 'g', hs.grid.show)
hs.hotkey.bind(capslock, 'Left', hs.grid.pushWindowLeft)
hs.hotkey.bind(capslock, 'Right', hs.grid.pushWindowRight)
hs.hotkey.bind(capslock, 'Up', hs.grid.pushWindowUp)
hs.hotkey.bind(capslock, 'Down', hs.grid.pushWindowDown)

-- misc hotkeys
hs.hotkey.bind(capslock, 'y', hs.toggleConsole)
hs.hotkey.bind(capslock, 'd', mouseHighlight)
hs.hotkey.bind(capslockshift, 'd', toggleDotFiles)



-- hs.hotkey.bind({"cmd", "alt", "ctrl"}, '1', function() hs.application.launchOrFocus('Sublime Text') end)
-- hs.hotkey.bind({"cmd", "alt", "ctrl"}, '2', function() hs.application.launchOrFocus('iTerm') end)
-- hs.hotkey.bind({"cmd", "alt", "ctrl"}, '3', function() hs.application.launchOrFocus('Google Chrome'); Grid.leftchunk(); end)
-- hs.hotkey.bind({"cmd", "alt", "ctrl"}, '4', function() hs.application.launchOrFocus('Slack') end)

-- Window management
hs.hotkey.bind(capslock, 'K', Grid.fullscreen)
hs.hotkey.bind(capslock, 'H', Grid.leftchunk)
hs.hotkey.bind(capslock, 'L', Grid.rightchunk)
hs.hotkey.bind(capslock, 'J', Grid.pushwindow)

hs.hotkey.bind(capslock, 'N', Grid.topleft)
hs.hotkey.bind(capslock, 'M', Grid.bottomleft)
hs.hotkey.bind(capslock, ',', Grid.topright)
hs.hotkey.bind(capslock, '.', Grid.bottomright)
hs.hotkey.bind(capslock, 'P', Grid.rightpeek)

-- hs.notify.new({
--   title='Hammerspoon',
--   informativeText='Config loaded'
-- }):send()

return sleepModule
