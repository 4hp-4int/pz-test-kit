-- The two shapes SaucedCarts 2.1.21 shipped. Both are wrong; see pz-test.lua.

local function install()
    local originalNew = ISUnequipAction.new
    -- Sends only character and item: NetTimedAction reads declared names.
    ISUnequipAction.new = function(self, character, item, ...)
        return originalNew(self, character, item, ...)
    end
    local originalComplete = ISUnequipAction.complete
    ISUnequipAction.complete = function(self)
        return originalComplete(self)
    end
end

-- A dedicated server never fires OnGameStart.
Events.OnGameStart.Add(install)
