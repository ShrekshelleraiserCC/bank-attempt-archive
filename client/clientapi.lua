local ecc = require("ecc")
local expect = require("cc.expect")

-- Messages will be sent over rednet
-- {type: string, message: string, sig: string}


local modem = peripheral.find("modem")
if #modem > 0 then
  -- there are multiple modems attached
  rednet.open(peripheral.getName(modem[1]))
elseif type(modem) == "table" then
  rednet.open(peripheral.getName(modem))
else
  error("A modem is required.")
end


local api = {}

api.error = {
  timed_out = "timed out",
  key_failure = "key failure", -- invalid key pairs, either the bank doesn't have our public key or we don't have the bank's public key
  auth_failure = "authentification failure", -- Account login information is incorrect
  access_denied = "access denied", -- attempted to access or do something that we don't have permssion for
  sig_invalid = "signature invalid", -- signiture doesn't match the message
  not_fount = "not found", -- requested resource doesn't exist
}

api.encryptedMessageTypes = {
  get = "get", -- {type=get, target, id}
  log_in = "log in", -- {type=log in, username, password}
  log_out = "log out", -- {type=log out}
  sign_up = "sign up", -- {type=sign up}
}

api.messageTypes = {
  encrypted = "encrypted",
  key_exchange = "key exchange",
  error = "error",
}

local private, public = ecc.keypair()
local bankPublic
local common -- key made with our private key, and the bank's public key
local bankId -- rednet ID of the bank
local lastKeyExchange = 0
local TIME_OUT = 1

--- Attempt to do key exchange and find the bank computer
-- @return bool success
function api.keyExchange()
  bankId = rednet.lookup("BANK_HOST")
  if type(bankId) == "nil" then
    return false
  elseif type(bankId) == "table" then
    error("Muliple banks are being hosted on this network..") -- just throw for now
  end
  -- {type: "key_exchange", message: <public key>, sig: <sig of public key>}
  local message = {type=api.messageTypes.key_exchange, message=public, sig=ecc.sign(private, public)}
  rednet.send(bankId, message, "BANK_CLIENT")
  local errCount = 0
  while errCount < 3 do
    local id, response, protocol = rednet.receive("BANK_HOST", TIME_OUT)
    if response and id == bankId then
      if response.type == api.messageTypes.key_exchange and ecc.verify(response.message, response.message, response.sig) then
        -- key_exchange, and signiture is valid
        bankPublic = response.message
        common = ecc.exchange(private, bankPublic)
        lastKeyExchange = os.epoch("utc")
        return true
        -- If this fails then we assume that the response type was incorrect, so we wait for the correct response type
      end
    elseif id == bankId then
      -- timed out, send the message again
      errCount = errCount + 1
      rednet.send(bankId, message, "BANK_CLIENT")
    end
  end
  return false
end

local function checkKeyAge()
  if lastKeyExchange + 1000 * 60 * 10 < os.epoch("utc") then
    -- more than 10 minutes passed since we last exchanged keys, so do it again
    if not api.keyExchange() then
      error("Unable to exchange keys with the bank.")
    end
  end
end

--- Wait for a valid message
-- Automatically handle some errors
-- auth_failure, sig_invalid
-- @param message: table message; ecryption and signitures are handled by this function
-- @return boolean success
-- @return table or error string
local function sendAndWaitForReply(message)
  expect(1, message, "table")
  checkKeyAge()
  local encryptedMessage = ecc.encrypt(textutils.serialize(message), common)
  local toSend = {type=api.messageTypes.encrypted, message=encryptedMessage, sig=ecc.sign(private, encryptedMessage)}
  local errCount = 0
  local lastErrReason
  rednet.send(bankId, toSend, "BANK_CLIENT")
  while errCount < 3 do
    local id, response = rednet.receive("BANK_HOST", TIME_OUT)
    if type("response") == "nil" then
      -- timeout
      errCount = errCount + 1
      lastErrReason = api.error.timed_out
    elseif response.type == api.messageTypes.encrypted and id == bankId then
      -- message is encrypted
      if ecc.verify(bankPublic, response.message, response.sig) then
        -- signiture is valid
        local decryptResponse = textutils.deserialize(ecc.decrypt(response.message, common))
        return true, decryptResponse
      else
        errCount = errCount + 1
        lastErrReason = api.error.sig_invalid
        -- signiture invalid, re-request the message
        rednet.send(bankId, toSend, "BANK_CLIENT")
      end
    elseif response.type == api.messageTypes.error and id == bankId then
      lastErrReason = response.message
      errCount = errCount + 1
      if response.message == api.error.key_failure then
        api.keyExchange()
      end
    elseif ecc.verify(bankPublic, response.message, response.sig) and id == bankId then
      -- signiture is valid, but message isn't encrypted
      return (not response.type == api.messageTypes.error), response.message
    elseif id == bankId then
      -- signiture is invalid
      errCount = errCount + 1
      lastErrReason = api.error.sig_invalid
      rednet.send(bankId, toSend, "BANK_CLIENT")
    end
  end
  return false, lastErrReason
end

local function get(target, id)
  local message = {type="get", target=target, id=id}
  return sendAndWaitForReply(message)
end

--- Get an account by ID
function api.getAccountByID(id)
  return get("accounts", id)
end

function api.getUserByID(id)
  return get("users", id)
end

function api.getTransactionByID(id)
  return get("transactions", id)
end

function api.getShareByID(id)
  return get("shares", id)
end

function api.getLoanByID(id)
  return get("loans", id)
end

--- Attempts to sign into an existing account
-- @return boolean; success
function api.logIn(username, password)
  password = ecc.sha256.digest(password)
  local message = {type="log in", username=username, password=password}
  local state, response = sendAndWaitForReply(message)
  return state
end

return api