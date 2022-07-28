@module BankAPI
local ecc = require("ecc")
local expect = require("cc.expect")
local bser = require("binserialize")
local db   = require("db")
local api = {}

api.bankdata = {
  accounts = {}, --
  shares = {},
  transactions = {},
  loans = {}, --
  users = {}, --
  passwords = {}, --
}

generateID = db.generateUUID

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

local password = {
  new = function(passwordString)
    local salt = generateID()
    local hashedPassword = ecc.sha256.digest(salt..passwordString)
    local pass = {
      id = generateID(),
      hashedPassword = hashedPassword,
      salt = salt,
    }
    api.bankdata.passwords[pass.id] = pass
    return pass
  end
}

setmetatable(password, {
  __eq = function(a,b)
    if type(a) == "string" and type(b) == "table" then
      local tmp = b
      b = a
      a = b
    end
    assertObjectType(a, "password")
    expect(2, b, "string")

    return a.hashedPassword == ecc.sha256.digest(a.salt..b)
  end
})

--- Generic interest object
-- Other objects that use interest features can inherit from this
api.interest = {
  __index = api.interest,

  types = {
    simple = "simple",
    compound = "compound",
  },

  --- Apply interest to object
  applyInterest = function (self)
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
}

--- User Object
api.user = {
  __index = api.user,
  new = function (username, passwordString)
    expect(1, username, "string")
    expect(2, passwordString, "string")
    if type(api.bankdata.users[username]) == "table" then
      error(string.format("Attempted to make user %s, user already exists!", username))
    end

    local pass = password.new(passwordString)
    local user = {
      id = username,
      accounts = { ref = "accounts" },
      password = { pass, ref = "passwords" }, -- This table is only ever expected to have one entry at [0]. It is a table so that I can reference/dereference as needed.
      meta = "user",
    }

    setmetatable(user, api.user)
    api.bankdata.users[username] = user
    api.log("Created new account for %s",username)
    return user
  end,

  --- Add an account to a user
  -- Also adds the user to the account
  addAccount = function (self,account)
    expect(1, account, "table")
    assertObjectType(account, "account")
    db.addLinkedReference(self, account, "accounts", "owners")
    api.log("user %s was added to account %s", self.id, account.id)
  end
}

--- Account Object
api.account = {
  __index = api.account,

  states = {
    normal = "normal",
    frozen = "frozen",
  },

  --- Create a new account AND add it to the currently loaded api.bankdata
  -- @param owner User object that will own this account
  -- @param accountName string name for this account
  -- @param args Optional key value table of account object parameters
  -- @return An Account object
  new = function (owner, accountName, args)
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
    db.addObject(owner.accounts, account)

    api.bankdata.accounts[account.id] = account
    return account
  end,

  --- Get the maximum loan this account can take without waiting for approval
  getMaxAutoApprovedLoan = function (self)
    local totalLoans = 0
    for k, v in pairs(self.loans) do
      if k ~= "ref" and v.state == api.loans.states.approved then
        totalLoans = totalLoans + v.balance
      end
    end
    return (self.maxAutoApprovedLoan - totalLoans)
  end,

  subtractFromBalance = function (self,amount)
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
  end,

  addToBalance = function (self,amount)
    self.balance = self.balance + amount
    return true
  end
}
setmetatable(api.account, api.interest) -- object can have interest applied

--- Loan Object
api.loan = {
  __index = api.loan,

  states = {
    pending_approval = "pending",
    approved = "approved",
    paid = "paid"
  },

  --- Create a new loan AND add it to the currently loaded api.bankdata AND add a reference to the account
  -- @param account Account object that will own this loan
  -- @param balance The initial balance of this loan
  -- @param args Optional key value table of loan object parameters
  -- @return Loan object
  new = function (account, balance, args)
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
    db.addObject(account.loans, loan)
    api.bankdata.loans[loan.id] = loan
    return loan
  end,

  --- Attempt to pay [value] amount off of loan
  -- will cap the payment to the remaining balance of loan
  -- and will automatically change loan state when balance = 0
  -- @param value amount to pay
  -- @return bool success
  pay = function (self,value)
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
  end,

  --- Change the state of the loan object
  changeState = function (self, newState)
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
}
setmetatable(api.loan, api.interest) -- object can have interest applied

--- Transaction object
api.transaction = {
  __index = api.transaction,

  states = {
    pending_hold = "pending_hold", -- attempting to take hold
    pending_approval = "pending_approval", -- hold has been taken, waiting for approval
    pending_transaction = "pending_transaction", -- pending, depending on another transaction
    approved = "approved", -- transaction has been approved, finalize it
    complete = "complete", -- transaction has been finished
    cancelled = "cancelled", -- transaction was cancelled

    pending_revert_hold = "pending_revert_hold", -- transaction reversion has been requested
    revert_hold = "revert_hold", -- hold has been taken from destination account
    reverted = "reverted", -- transaction was reverted; fraud
  },

  -- ENTRY POINT -> pending_hold
  -- pending_hold -> pending_approval
  -- pending_approval - USER ACTION -> approved
  -- approved -> complete

  -- complete -?> pending_revert
  -- pending_revert -> revert_hold
  -- revert_hold -> reverted
  -- pending_hold, pending_approval, approved - USER ACTION -> cancelled

  types = {
    currency_transfer = "currency_transfer",
    -- accounts {[1]source, [2]destination}, type, state, balance, id, created
    share_transfer = "share_transfer",
    -- accounts {[1]source, [2]destination}, type, state, share, id, created, linkedTransfer {[1]}
    deposit = "deposit",
    -- accounts {[1]}, type, state, balance, id, created
    withdrawl = "withdrawl",
    -- accounts {[1]}, type, state, balance, id, created
  },

  --- Create a new transaction object
  -- auto links to accounts
  -- @param amount: number
  -- @param sourceAccount: account object
  -- @param destAccount: account object
  -- @param args: table or nil
  -- @return transaction object
  newCurrency = function(amount, sourceAccount, destinationAccount, args)
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
    db.addObject(sourceAccount.transactions, transaction)
    db.addObject(destinationAccount.transactions, transaction)
    api.bankdata.transactions[transaction.id] = transaction
    return transaction
  end,
  --- Create a new transaction object
  -- auto links to accounts
  -- @param amount: number
  -- @param account: account object
  -- @param args: table or nil
  -- @return transaction object
  newDeposit = function (amount, account, args)
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
    db.addObject(account.transactions, transaction)
    api.bankdata.transactions[transaction.id] = transaction
    return transaction
  end,

  --- Create a new transaction object
  -- auto links to accounts
  -- @param amount: number
  -- @param account: account object
  -- @param args: table or nil
  -- @return transaction object, boolean success
  newWithdrawl = function (amount, account, args)
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
    db.addObject(account.transactions, transaction)
    api.bankdata.transactions[transaction.id] = transaction
    transaction:tick() -- attempt transaction and return if it succeeded
    return transaction, (transaction.state == api.transaction.states.complete)
  end,

  --- Create a new transaction object
  -- auto links to accounts
  -- @param share: share object
  -- @param sourceAccount: account object
  -- @param destinationAccount: account object
  -- @param linkedTransaction: transaction object
  -- @param args: table or nil
  -- @return transaction object
  newShare = function (share, sourceAccount, destinationAccount, linkedTransaction, args)
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
    db.addObject(sourceAccount.transactions, transaction)
    db.addObject(destinationAccount.transactions, transaction)
    api.bankdata.transactions[transaction.id] = transaction

    return transaction
  end,


  --- Process the transaction
  tick = function (self)
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
        -- attempt to take back and hold the currency that was transfered
        if self.accounts[2]:subtractFromBalance(self.balance) then
          self.state = api.transaction.states.revert_hold
        end
      elseif self.state == api.transaction.states.revert_hold then
        -- hold has been reverted
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
          self.share:setOwner(self.destinationAccount)
        elseif self.linkedTransfer.state == api.transaction.states.cancelled then
          self:cancel()
        end
      end
    end
  end,

  --- Attempt to cancel the transaction
  -- @return bool if it succeeded
  cancel = function (self)
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
  end,

  --- Attempt to revert the transaction
  -- @return bool if it succeeded
  revert = function (self)
    if self.state == api.transaction.states.complete then
      self.state = api.transaction.states.pending_revert_hold
      return true
    end
    return false
  end
}

--- Share Stuff
api.share = {
  __index = api.share,

  --- Create a new share
  -- @param account account object
  -- @return nil or share object
  new = function (account)
    if not account.publicallyTraded then return end
    local share = {
      issuingAccount = {account, ref="accounts"},
      owner = {account, ref="accounts"},
      id = generateID(),
      meta = "share"
    }
    db.addObject(account.shares, share)
    api.bankdata.shares[share.id] = share
    setmetatable(share, api.share)
    api.log("share created for account %s", account.id)
    return share
  end,

  --- Clear the owner of this share
  -- @return boolean success
  clearOwner = function (self)
    local index = getKeyOfTable(self.owner[1].shares, "id", self.id)
    if index then
      table.remove(self.owner[1].shares, index)
      self.owner[1] = nil
      return true
    end
    return false
  end,

  --- Attempt to set the owner of this share
  -- @param account account object
  -- @return boolean success
  setOwner = function (self, account)
    self:clearOwner()
    self.owner[1] = account
    account.shares[#account.shares+1] = self
    return true
  end
}

--- Save api.bankdata to a file
-- @return boolean success
function api.saveapi.bankdata(filename)
  return db.saveRecursiveTable(api.bankdata, filename)
end

--- Load api.bankdata from a file
-- @return boolean success
function api.loadapi.bankdata(filename)
  local bdata = db.loadRecursiveTable(filename, api)
  if bdata then
    api.bankdata = bdata
    return true
  end
  return false
end


return api
