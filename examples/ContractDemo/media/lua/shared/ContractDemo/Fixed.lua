-- The correct shapes. The contract must stay quiet about these.

local function install()
    local originalNew = ISEatFoodAction.new
    -- Vanilla's exact signature, names included.
    ISEatFoodAction.new = function(self, character, item, percentage)
        return originalNew(self, character, item, percentage)
    end
    local originalComplete = ISEatFoodAction.complete
    ISEatFoodAction.complete = function(self)
        return originalComplete(self)
    end
end

-- OnGameBoot fires in SP, on an MP client and on a dedicated server.
Events.OnGameBoot.Add(install)
