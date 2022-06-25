local b = require("bankapi")
local ecc = require("ecc")
local server = require("server")

b.loadBankData("BANKDATA")

local srv = server.new("BANK", "The Bank")
srv.msgHandle = function(self, id, msg)
  -- msg from the client will be a table where the first element is the request type
  if msg[1] == "login" then
    
  end
end