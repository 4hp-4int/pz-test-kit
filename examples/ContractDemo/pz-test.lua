--[[
    ContractDemo — fixture for the kit's contract pass (kahlua/contract.lua).

    `pztest` here MUST report two contract failures, both from Broken.lua,
    and nothing from Fixed.lua. If either check stops failing, the contract
    has gone blind; if Fixed.lua shows up, it has a false positive.

      Broken.lua  ISUnequipAction.new wrapped with `...`  -> signatures check
                  ISUnequipAction.complete hooked from OnGameStart
                                                       -> dedi hooks check
      Fixed.lua   ISEatFoodAction.new wrapped with the full signature,
                  ISEatFoodAction.complete hooked from OnGameBoot (fires on
                  every machine)                       -> passes both
]]

return {}
