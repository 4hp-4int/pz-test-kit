--[[
    PZ Test Kit — client-index tag
    ===============================
    Stamps `_pz_player._client_index` so 4-arg `sendServerCommand(player, ...)`
    from the server env can route to the correct client endpoint. Input:
        _pz_client_index — integer client number (1..N)
]]

if _pz_player and _pz_client_index then
    _pz_player._client_index = _pz_client_index
end
