local ecc = require("ecc")
local expect = require("cc.expect")
local api = {}

BankData = BankData or {
  accounts = {}, --
  shares = {},
  transactions = {},
  loans = {}, --
  users = {}, --
  passwords = {}, --
}

-- https://gist.github.com/jrus/3197011
local function generateID()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return string.gsub(template, '[xy]', function(c)
    local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format('%x', v)
  end)
  -- local idString = os.date()..tostring(math.random(1, 100000))
  -- return ecc.sha256.digest(idString)
end

local function assertObjectType(objectTable, objectType)
  expect(1, objectTable, "table")
  if objectTable.meta ~= objectType then
    error(string.format("Expected object of type %s, got %s", objectType, objectTable.meta), 2)
  end
end

local function getKeyOfValue(T, value)
  for k,v in pairs(T) do
    if v == value then
      return k
    end
  end
  return false
end


--- Returns the index of a table in T that contains value at key
local function getKeyOfTable(T, key, value)
  for k, v in pairs(T) do
    if v[key] == value then
      return k
    end
  end
  return false
end

local function removeElementByValue(T, value)
  local index = getKeyOfValue(T, value)
  if index then
    table.remove(T, index)
    return true
  end
  return false
end

function api.log(str, ...)
  local log = string.format("[%s] ", os.date("%R:%S"))
  log = log .. string.format(str, table.unpack(arg))
  print(log)
end

local password = {}
function password.new(hashedPassword)
  local pass = {
    id = generateID(),
    hashedPassword = hashedPassword,
  }
  BankData.passwords[pass.id] = pass
  return pass
end

--- Generic interest object
-- Other objects that use interest features can inherit from this
api.interest = {}
api.interest.__index = api.interest

api.interest.types = {
  simple = "simple",
  compound = "compound",
}

--- Apply interest to object
function api.interest:applyInterest()
  self.lastInterestTime = self.lastInterestTime or os.epoch("utc") -- automatically add this field to anything that doesn't have it
  if self.lastInterestTime + 1000*60*60*24 < os.epoch("utc") then
    -- 24 hours have passed
    api.log("interest applied to %s", self.id)
    if self.interestType == api.interest.types.simple then
      self.initialBalance = self.initialBalance or self.balance
      self.balance = self.balance + (self.initialBalance * self.interestRate)
    elseif self.interestType == api.interest.types.compound then
      self.balance = self.balance + (self.balance * self.interestRate)
    end
    self.lastInterestTime = os.epoch("utc")
  end
end

--- User Object
api.user = {}
api.user.__index = api.user
function api.user.new(username, hashedPassword)
  expect(1, username, "string")
  expect(2, hashedPassword, "string")
  if type(BankData.users[username]) == "table" then
    error(string.format("Attempted to make user %s, user already exists!", username))
  end

  local pass = password.new(hashedPassword)
  local user = {
    id = username,
    accounts = { ref = "accounts" },
    password = { pass, ref = "passwords" }, -- This table is only ever expected to have one entry at [0]. It is a table so that I can reference/dereference as needed.
    meta = "user",
  }

  setmetatable(user, api.user)
  BankData.users[username] = user
  api.log("Created new account for %s",username)
  return user
end

--- Add an account to a user
-- Also adds the user to the account
function api.user:addAccount(account)
  expect(1, account, "table")
  assertObjectType(account, "account")
  self.accounts[#self.accounts + 1] = account
  account.owners[#account.owners + 1] = self
  api.log("user %s was added to account %s", self.id, account.id)
end

--- Account Object
api.account = {}
api.account.__index = api.account
setmetatable(api.account, api.interest) -- object can have interest applied

api.account.states = {
  normal = "normal",
  frozen = "frozen",
}

--- Create a new account AND add it to the currently loaded BankData
-- @param owner User object that will own this account
-- @param accountName string name for this account
-- @param args Optional key value table of account object parameters
-- @return An Account object
function api.account.new(owner, accountName, args)
  expect(1, owner, "table")
  assertObjectType(owner, "user")
  expect(2, accountName, "string")
  local account = {
    name = accountName,
    owners = { owner, ref = "users" },
    loans = { ref = "loans" }, -- ref is a keyword indicating how to serialize this table
    transactions = { ref = "transactions" },

    publicallyTraded = false,
    totalShares = 0,
    shares = { ref = "shares" },

    balance = 1000,

    doInterest = true,
    interestType = api.interest.types.compound,
    interestRate = 0.01,
    lastInterestTime = os.day(),

    doOverdraft = true,
    maxAutoApprovedLoan = 1000,

    state = api.account.states.normal,
    id = generateID(),

    meta = "account", -- meta is a keyword indicating how to deserialize this table
  }
  args = args or {}
  for key, value in pairs(args) do
    -- apply arguments
    account[key] = value
  end
  setmetatable(account, api.account)

  owner.accounts[#owner.accounts + 1] = account

  BankData.accounts[account.id] = account
  return account
end

--- Get the maximum loan this account can take without waiting for approval
function api.account:getMaxAutoApprovedLoan()
  local totalLoans = 0
  for k, v in pairs(self.loans) do
    if k ~= "ref" and v.state == api.loans.states.approved then
      totalLoans = totalLoans + v.balance
    end
  end
  return (self.maxAutoApprovedLoan - totalLoans)
end

function api.account:subtractFromBalance(amount)
  expect(1, amount, "number")
  if self.state ~= api.account.states.frozen then
    if amount <= self.balance then
      -- No problem, just withdraw the money
      self.balance = self.balance - amount
      return true, amount
    elseif self.doOverdraft then
      -- attempt to do overdraft
      local loanAmount = amount - self.balance
      if loanAmount <= self:getMaxAutoApprovedLoan() then
        api.loan.new(self, loanAmount)
        return true, amount
      end
      -- If falls through -> loan would be delayed, so don't bother with overdraft
    end
  end
  return false
end

function api.account:addToBalance(amount)
  self.balance = self.balance + amount
  return true
end

--- Loan Object
api.loan = {}
api.loan.__index = api.loan
setmetatable(api.loan, api.interest) -- object can have interest applied

api.loan.states = {
  pending_approval = "pending",
  approved = "approved",
  paid = "paid"
}

--- Create a new loan AND add it to the currently loaded BankData AND add a reference to the account
-- @param account Account object that will own this loan
-- @param balance The initial balance of this loan
-- @param args Optional key value table of loan object parameters
-- @return Loan object
function api.loan.new(account, balance, args)
  expect(1, account, "table")
  assertObjectType(account, "account")
  expect(2, balance, "number")
  args = args or {}
  local loan = {
    account = { account, ref = "accounts" },
    dateTaken = os.epoch("utc"),

    balance = balance,
    initialBalance = balance,

    interestRate = 0.05,
    interestType = api.interest.types.simple,
    doInterest = false,

    state = api.loan.states.pending_approval,
    id = generateID(),

    meta = "loan"
  }

  args = args or {}
  for k, v in pairs(args) do
    loan[k] = v
  end
  if loan.balance <= account:getMaxAutoApprovedLoan() then
    loan:changeState(api.loan.states.approved)
  end
  setmetatable(loan, api.loan)
  BankData.loans[loan.id] = loan
  account.loans[#account.loans + 1] = BankData.loans[loan.id]
  return loan
end

--- Attempt to pay [value] amount off of loan
-- will cap the payment to the remaining balance of loan
-- and will automatically change loan state when balance = 0
-- @param value amount to pay
-- @return bool success
function api.loan:pay(value)
  expect(1, value, "number")
  if self.state == api.loans.states.approved then
    value = math.min(value, self.balance)
    local success, amount = self.account[1]:subtractFromBalance()
    if success then
      self.balance = self.balance - amount
      if self.balance == 0 then
        self:changeState(api.loan.states.paid)
      end
    end
  end
end

--- Change the state of the loan object
function api.loan:changeState(newState)
  expect(1, newState, "string")
  if newState ~= self.state then
    -- ensure new state differs
    if newState == api.loan.states.approved then
      self.doInterest = true
      self.state = newState
      self.account:addToBalance(self.balance)
    elseif newState == api.loan.states.paid then
      self.doInterest = false
      self.state = newState
    end
  end
end

--- Transaction object
api.transaction = {}
api.transaction.__index = api.transaction

api.transaction.states = {
  pending_hold = "pending_hold", -- attempting to take hold
  pending_approval = "pending_approval", -- hold has been taken, waiting for approval
  pending_transaction = "pending_transaction", -- pending, depending on another transaction
  approved = "approved", -- transaction has been approved, finalize it
  complete = "complete", -- transaction has been finished
  cancelled = "cancelled", -- transaction was cancelled

  pending_revert_hold = "pending_revert_hold", -- transaction reversion has been requested
  revert_hold = "revert_hold", -- hold has been taken from destination account
  reverted = "reverted", -- transaction was reverted; fraud
}

-- ENTRY POINT -> pending_hold
-- pending_hold -> pending_approval
-- pending_approval - USER ACTION -> approved
-- approved -> complete

-- complete -?> pending_revert
-- pending_revert -> revert_hold
-- revert_hold -> reverted
-- pending_hold, pending_approval, approved - USER ACTION -> cancelled

api.transaction.types = {
  currency_transfer = "currency_transfer",
  -- accounts {[1]source, [2]destination}, type, state, balance, id, created
  share_transfer = "share_transfer",
  -- accounts {[1]source, [2]destination}, type, state, share, id, created, linkedTransfer {[1]}
  deposit = "deposit",
  -- accounts {[1]}, type, state, balance, id, created
  withdrawl = "withdrawl",
  -- accounts {[1]}, type, state, balance, id, created
}

--- Create a new transaction object
-- auto links to accounts
-- @param amount: number
-- @param sourceAccount: account object
-- @param destAccount: account object
-- @param args: table or nil
-- @return transaction object
function api.transaction.newCurrency(amount, sourceAccount, destinationAccount, args)
  expect(1, amount, "number")
  expect(2, sourceAccount, "table")
  assertObjectType(sourceAccount, "account")
  expect(3, destinationAccount, "table")
  assertObjectType(destinationAccount, "account")

  local transaction = {
    accounts = { sourceAccount, destinationAccount, ref = "accounts" },

    type = api.transaction.types.currency_transfer,
    state = api.transaction.states.pending_hold,

    balance = amount,

    id = generateID(),

    created = os.epoch("utc"),

    meta = "transaction"
  }
  args = args or {}
  for k, v in pairs(args) do
    transaction[k] = v
  end
  setmetatable(transaction, api.transaction)
  sourceAccount.transactions[#sourceAccount.transactions+1] = transaction
  destinationAccount.transactions[#destinationAccount.transactions+1] = transaction
  BankData.transactions[transaction.id] = transaction
  return transaction
end
--- Create a new transaction object
-- auto links to accounts
-- @param amount: number
-- @param account: account object
-- @param args: table or nil
-- @return transaction object
function api.transaction:newDeposit(amount, account, args)
  expect(1, amount, "number")
  expect(2, account, "table")
  assertObjectType(account, "account")
  local transaction = {
    accounts = { account, ref = "accounts" },

    type = api.transaction.types.deposit,
    state = api.transaction.states.approved,

    balance = amount,

    id = generateID(),

    created = os.epoch("utc"),

    meta = "transaction"
  }
  args = args or {}
  for k, v in pairs(args) do
    transaction[k] = v
  end
  setmetatable(transaction, api.transaction)
  account.transactions[#account.transactions+1] = transaction
  BankData.transactions[transaction.id] = transaction
  return transaction
end

--- Create a new transaction object
-- auto links to accounts
-- @param amount: number
-- @param account: account object
-- @param args: table or nil
-- @return transaction object, boolean success
function api.transaction:newWithdrawl(amount, account, args)
  expect(1, amount, "number")
  expect(2, account, "table")
  assertObjectType(account, "account")
  local transaction = {
    accounts = { account, ref = "accounts" },

    type = api.transaction.types.withdrawl,
    state = api.transaction.states.approved,

    balance = amount,

    id = generateID(),

    created = os.epoch("utc"),

    meta = "transaction"
  }
  args = args or {}
  for k, v in pairs(args) do
    transaction[k] = v
  end
  setmetatable(transaction, api.transaction)
  account.transactions[#account.transactions+1] = transaction
  BankData.transactions[transaction.id] = transaction
  transaction:tick() -- attempt transaction and return if it succeeded
  return transaction, (self.state == api.transaction.states.complete)
end

--- Create a new transaction object
-- auto links to accounts
-- @param share: share object
-- @param sourceAccount: account object
-- @param destinationAccount: account object
-- @param linkedTransaction: transaction object
-- @param args: table or nil
-- @return transaction object
function api.transaction.newShare(share, sourceAccount, destinationAccount, linkedTransaction, args)
  expect(1, share, "table")
  assertObjectType(share, "share")
  expect(2, sourceAccount, "table")
  assertObjectType(sourceAccount, "account")
  expect(3, destinationAccount, "table")
  assertObjectType(destinationAccount, "account")
  expect(4, linkedTransaction, "table")
  assertObjectType(linkedTransaction, "transaction")
  local transaction = {
    accounts = { sourceAccount, destinationAccount, ref = "accounts" },

    type = api.transaction.types.share_transfer,
    state = api.transaction.states.pending_hold,

    share = share,
    linkedTransfer = {linkedTransaction, ref="transfers"},

    id = generateID(),

    created = os.epoch("utc"),

    meta = "transaction"
  }
  args = args or {}
  for k, v in pairs(args) do
    transaction[k] = v
  end
  setmetatable(transaction, api.transaction)
  sourceAccount.transactions[#sourceAccount.transactions+1] = transaction
  destinationAccount.transactions[#destinationAccount.transactions+1] = transaction
  BankData.transactions[transaction.id] = transaction

  return transaction
end

--- Process the transaction
function api.transaction:tick()
  -- process transaction
  if self.type == api.transaction.types.currency_transfer then
    if self.state == api.transaction.states.pending_hold then
      -- attempt to withdraw the hold
      if self.accounts[1]:subtractFromBalance(self.balance) then
        self.state = api.transaction.states.pending_approval
      end
    elseif self.state == api.transaction.states.approved then
      -- complete the transaction
      if self.accounts[2]:addToBalance(self.balance) then
        self.state = api.transaction.states.complete
      end
    elseif self.state == api.transaction.states.pending_revert_hold then
      if self.accounts[2]:subtractFromBalance(self.balance) then
        self.state = api.transaction.states.revert_hold
      end
    elseif self.state == api.transaction.states.revert_hold then
      if self.accounts[1]:addToBalance(self.balance) then
        self.state = api.transaction.states.reverted
      end
    end

  elseif self.type == api.transaction.types.deposit then
    if self.state == api.transaction.states.approved then
      if self.accounts[1]:addToBalance(self.balance) then
        self.state = api.transaction.states.complete
      end
    end
  elseif self.type == api.transaction.types.withdrawl then
    if self.state == api.transaction.states.approved then
      if self.accounts[1]:subtractFromBalance(self.balance) then
        self.state = api.transaction.states.complete
      else
        self.state = api.transaction.states.cancelled
      end
    end

  elseif self.type == api.transaction.types.share_transfer then
    if self.state == api.transaction.states.pending_transaction then
      if self.linkedTransfer.state == api.transaction.states.complete then
        --self.share:setOwner(self.destinationAccount)
      elseif self.linkedTransfer.state == api.transaction.states.cancelled then
        self:cancel()
      end
    end
  end
end

--- Attempt to cancel the transaction
-- @return bool if it succeeded
function api.transaction:cancel()
  if self.type == api.transaction.types.currency_transfer then
    if self.state == api.transaction.states.pending_hold then
      self.state = api.transaction.states.cancelled
      return true
    elseif self.state == api.transaction.states.pending_approval or
      self.state == api.transaction.states.approved then
      if self.account[1]:addToBalance(self.balance) then
        self.state = api.transaction.states.cancelled
        return true
      end
    end
  end
  return false
end

--- Attempt to revert the transaction
-- @return bool if it succeeded
function api.transaction:revert()
  if self.state == api.transaction.states.complete then
    self.state = api.transaction.states.pending_revert_hold
    return true
  end
  return false
end

--- Share Stuff
api.share = {}
api.share.__index = api.share

--- Create a new share
-- @param account account object
-- @return nil or share object
function api.share.new(account)
  if not account.publicallyTraded then return end
  local share = {
    issuingAccount = {account, ref="accounts"},
    owner = {account, ref="accounts"},
    id = generateID(),
    meta = "share"
  }
  account.shares[#account.shares+1] = share
  BankData.shares[share.id] = share
  setmetatable(share, api.share)
  api.log("share created for account %s", account.id)
  return share
end

--- Loading Stuff
local function isValueInTable(value, T)
  for k, v in pairs(T) do
    if v == value then
      return true
    end
  end
  return false
end

--- Dereference the IDs contained in a table with ref defined.
-- ID String -> Reference to table
local function dereferenceIDsInTable(T, refStack)
  print(debug.traceback())
  expect(1, T, "table")
  refStack = refStack or {}

  for key, value in pairs(T) do
    if T.ref and key ~= "ref" then
      assert(type(value) == "string", "Attempt to dereference non-string ID.")
      assert(type(BankData[T.ref][value]) ~= "nil", string.format("Attempt to de-reference non-existant ID %s of type %s", value, T.ref))
      T[key] = BankData[T.ref][value]

    elseif key ~= "ref" and type(value) == "table" then
      if not isValueInTable(key, refStack) then
        -- Ensure we're not iterating over duplicate items
        refStack[#refStack + 1] = key
        dereferenceIDsInTable(T[key], refStack)
        refStack[#refStack] = nil
      end
    end
  end
end

--- Reference to table -> ID String
local function referenceIDsInTable(T, refStack)
  expect(1, T, "table")
  refStack = refStack or {}
  for key, value in pairs(T) do
    if T.ref and key ~= "ref" then
      assert(type(value) == "table", "Attempt to reference non-table.")
      assert(type(value.id) ~= "nil", "Attempt to reference object with no ID")
      T[key] = value.id

    elseif key ~= "ref" and type(value) == "table" then
      if not isValueInTable(key, refStack) then
        -- Ensure we're not iterating over duplicate items
        refStack[#refStack + 1] = key
        referenceIDsInTable(T[key], refStack)
        refStack[#refStack] = nil
      end
    end
  end
end

local function applyMetatables(T, refStack)
  expect(1, T, "table")
  refStack = refStack or {}
  if type(T.meta) == "string" then
    setmetatable(T, api[T.meta])
  end
  for key, value in pairs(T) do
    if type(value) == "table" and not isValueInTable(key, refStack) then
      refStack[#refStack + 1] = key
      applyMetatables(T[key], refStack)
      refStack[#refStack] = nil
    end
  end
end

--- Reference to table -> ID String; but in a deep clone of the original table
-- @param T table
-- @return table
local function referenceIDsInTableClone(T, refStack)
  expect(1, T, "table")
  refStack = refStack or {}
  local tmpT = {}
  for key, value in pairs(T) do
    if T.ref and key ~= "ref" then
      assert(type(value) == "table", "Attempt to reference non-table.")
      assert(type(value.id) ~= "nil", "Attempt to reference object with no ID")
      tmpT[key] = value.id

    elseif key ~= "ref" and type(value) == "table" then
      if not isValueInTable(key, refStack) then
        -- Ensure we're not iterating over duplicate items
        refStack[#refStack + 1] = key
        tmpT[key] = referenceIDsInTableClone(T[key], refStack)
        refStack[#refStack] = nil
      end
    else
      tmpT[key] = value
    end
  end
  return tmpT
end

--- Serialize a recursive/reference filled table
-- @param T table to serialize
-- @param compact optional boolean to compact string; default true
-- @return string serialized table
function api.serializeRecursiveTable(T, compact)
  expect(1, T, "table")
  if type(compact) ~= "boolean" then compact = true end
  local tmpT = referenceIDsInTableClone(T)
  return textutils.serialize(tmpT, { compact = true })
end

--- Save BankData to a file
-- @return boolean success
function api.saveBankData(filename)
  if fs.exists(filename .. "BAK") then
    fs.delete(filename .. "BAK")
  end
  if fs.exists(filename) then
    fs.copy(filename, filename .. "BAK")
  end
  local f = fs.open(filename, "w")
  if f then
    f.write(api.serializeRecursiveTable(BankData))
    f.close()
    return true
  end
  return false
end

--- Load BankData from a file
-- @return boolean success
function api.loadBankData(filename)
  local f = fs.open(filename, "r")
  if f then
    BankData = textutils.unserialise(f.readAll())
    dereferenceIDsInTable(BankData)
    applyMetatables(BankData)
    f.close()
    return true
  end
  return false
end

return api
