RegisterNetEvent("az_fishing:sellFish", function(totalValue)
    local src = source

    if not totalValue or type(totalValue) ~= "number" or totalValue <= 0 then return end

    local success, err = pcall(function()
        if exports['Az-Framework'] ~= nil and exports['Az-Framework'].addMoney ~= nil then
            exports['Az-Framework']:addMoney(src, totalValue)
        end
    end)
    if not success then print("az_fishing: failed to sell fish", err) end

    TriggerClientEvent('chat:addMessage', src, {
        args = { "[Fishing]", "You received $" .. totalValue .. " for your fish." }
    })
end)
