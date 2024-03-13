--!strict

-- Marketer
-- a marketplace service wrapper with usd and robux subscriptions, and some asset utilities aswell
-- @Kalrnlo
-- 07/03/2024

local MarketplaceService = game:GetService("MarketplaceService")
local DatastoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

type Future<T...> = {
	ValueList: { any }?,
	AfterList: { (T...) -> () },
	YieldList: { thread },

	IsComplete: (self: Future<T...>) -> boolean,
	IsPending: (self: Future<T...>) -> boolean,

	Expect: (self: Future<T...>, Message: string) -> T...,
	Unwrap: (self: Future<T...>) -> T...,
	UnwrapOr: (self: Future<T...>, T...) -> T...,
	UnwrapOrElse: (self: Future<T...>, Else: () -> T...) -> T...,

	After: (self: Future<T...>, Callback: (T...) -> ()) -> (),
	Await: (self: Future<T...>) -> T...,
}

type PeroidStruct = {
    Months: number,
    Years: number,
    Days: number,
}

export type Period = Enum.SubscriptionPeriod | PeroidStruct

export type SubscriptionType = "Dual" | "Robux" | "USD"

type SubscriptionHistoryEntry = {
    PaymentStatus: Enum.SubscriptionPaymentStatus,
    PeroidStart: DateTime,
    PeroidEnd: DateTime,
}

export type SubscriptionHistory = {SubscriptionHistoryEntry}

export type Subscription = {
    PlayerUnsubscribed: (self: Subscription, Callback: (Player: Player, ExpirationReason: Enum.SubscriptionExpirationReason) -> ()) -> () -> (),
    Subscribe: (self: Subscription, PlayerOrUserId: Player | number, Period: Enum.SubscriptionPeriod?) -> (),
    GetState: (self: Subscription, PlayerOrUserId: Player | number) -> Enum.SubscriptionState,
    GetHistory: (self: Subscription, PlayerOrUserId: Player | number) -> SubscriptionHistory,
    Prompt: (self: Subscription, Player: Player) -> Future<boolean, Enum.SubscriptionState>,
    PlayerSubscribed: (self: Subscription, Callback: (Player: Player) -> ()) -> () -> (),
    IsSubscribed: (self: Subscription, PlayerOrUserId: Player | number) -> boolean,
    Deactivate: (self: Subscription) -> (),
    Activate: (self: Subscription) -> (),

    Subscribers: {Player},
    ProviderName: string,
    Description: string,
    Activated: boolean,
    Perks: {string},
    Name: string,
    Icon: number,
}

export type TieredSubscription = Subscription & ({
	Peroids: {
		({
			DisplayPeriod: string,
			DisplayPrice: string,
			ProductId: number,
			Peroid: Peroid,
			TierType: "Robux",
        	} | {
			Peroid: Enum.SubscriptionPeriod,
			SubscriptionId: string,
			DisplayPeriod: string,
			DisplayPrice: string,
			TierType: "USD",
		} | {
			Peroid: Enum.SubscriptionPeriod,
			RobuxDisplayPrice: string,
			USDDisplayPrice: string,
			SubscriptionId: string,
			DisplayPeriod: string,
			ProductId: number,
			TierType: "Dual",
		})
	}
})

export type TierType = SubscriptionType

export type RobuxSubscription = Subscription & {
	SubscriptionType: "Robux",
	DisplayPeriod: string,
	DisplayPrice: string,
	ProductId: number,
	Peroid: Peroid,
}

export type USDSubscription = Subscription & {
	Peroid: Enum.SubscriptionPeriod,
	SubscriptionType: "USD",
	SubscriptionId: string,
	DisplayPeriod: string,
	DisplayPrice: string,
} 

export type DualSubscription = Subscription & {
	Peroid: Enum.SubscriptionPeriod,
	RobuxDisplayPrice: string,
	SubscriptionType: "Dual",
	USDDisplayPrice: string,
	SubscriptionId: string,
	DisplayPeriod: string,
	ProductId: number,
}

type ReciptInfo = {
    CurrencyType: Enum.CurrencyType,
    PlaceIdWherePurchased: number,
    CurrencySpent: number,
    PurchaseId: number,
    ProductId: number,
    PlayerId: number,
}

export type Recipt = {
    Currency: Enum.CurrencyType,
    PlaceWhereBought: number,
    Spent: number,
}

type Config = {
    SubscriptionKeyFormat: string?,
    ProductKeyFormat: string?,
    DatastoreName: string?,
}

type ProductCallback = (Player: Player, PurchaseId: number, Recipt: Recipt) -> boolean
type GamepassCallback = (Player: Player) -> ()

-- Any table with Player prefixing its name uses UserIds as keys
local ProductToSubscriptionMap = {} :: {[number]: RobuxSubscription | DualSubscription}
local Subscriptions = {} :: {RobuxSubscription | DualSubscription | USDSubscription}
local GamepassCallbacks = {} :: {[number]: {(Player: Player) -> ()}}
local ProductCallbacks = {} :: {[number]: ProductCallback}
local IsServer = game:GetService("RunService"):IsServer()
local PlayerSubscriptions = {} :: {[number]: {string}}
local PlayerWriteQueues = {} :: {[number]: {thread}}
local PlayerGamepasses = {} :: {[number]: {number}}
local PlayersLoading = {} :: {[number]: {thread}}
local Datastore: DataStore
local Config = {
    SubscriptionKeyFormat = "[SUBSCRIPTION_%s]",
    ProductKeyFormat = "[PRODUCT_%s]_%s_%s",
    DatastoreName = "Marketer",
}

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

local SubscriptionPaymentStatusToNumber = {
    [Enum.SubscriptionPaymentStatus.Refunded] = 1,
    [Enum.SubscriptionPaymentStatus.Paid] = 2,
    Robux = 0,
}
local SubscriptionTypeEnum = {
    Robux = 1,
    Dual = 2,
    USD = 3,
}
-- Array to hold the number of days in each month (non-leap year)
local MonthLengths = table.create(12, 31)
MonthLengths[2] = 28
MonthLengths[4] = 30
MonthLengths[5] = 30
MonthLengths[9] = 30
MonthLengths[11] = 30

local function DaysBetweenDates(Day1: number, Month1: number, Year1: number, Day2: number, Month2: number, Year2: number)
    local Days = 0

    while Day1 < Day2 or Month1 < Month2 or Year1 < Year2 do
        local DaysInMonth = if Month1 == 2 then
                (if Year1 % 4 == 0 and (Year1 % 100 ~= 0 or Year1 % 400 == 0) then 29 else 28)
            else
                MonthLengths[Month1]
        Day1 += 1

        if Day1 > DaysInMonth then
            Month1 += 1
            Day1 = 1

            if Month1 > 12 then
                Month1 = 1
                Year1 += 1
            end
        end
        Days += 1
    end
    return Days
end

local function AddDates(Day1: number, Month1: number, Year1: number, Day2: number, Month2: number, Year2: number)
	local Month = if Month1 == 0 or Month2 == 0 then 
			Month1 + Month2
		else
			Month1 + math.abs(Month1 - Month2)
	local PreviousMonth = Month - 1
	local Day = Day1 + Day2
	
	local Year = (if Year2 == 0 or Year1 == 0 then 
			Year1 + Year2 
		else 
			Year1 + math.abs(Year1 - Year2)
	) + (PreviousMonth // 12)
	Month = (PreviousMonth % 12) + 1
	local DaysInMonth = if Month == 2 then
			(if Year % 4 == 0 and (Year % 100 ~= 0 or Year % 400 == 0) then 29 else 28)
		else
			MonthLengths[Month]
			
	while Day > DaysInMonth do
			Day -= DaysInMonth
			Month += 1
				
			if NewMonth > 12 then
					DaysInMonth = 31
					Month = 1
					Year += 1
			else
				DaysInMonth = if Month == 2 then
						(if Year % 4 == 0 and (Year % 100 ~= 0 or Year % 400 == 0) then 29 else 28)
					else
						MonthLengths[Month]
			end
	end
	return Day, Month, Year
end

local function PackDate(Day: number, Month: number, Year: number)
    return bit32.bor(bit32.lshift(Year, 9), bit32.lshift(Month, 5), Day)
end

local function UnpackDate(u32Date: number)
	return bit32.band(u32Date, 0x1F),
		bit32.band(bit32.rshift(u32Date, 5), 0xF),
		bit32.rshift(u32Date, 9)
end

local function SwapRemove<T>(Array: {T}, Index: number)
    if #Array ~= 1 then
        Array[Index] = Array[#Array]
        Array[#Array] = nil
    else
        Array[Index] = nil
    end
end

--------------------------------------------------------------------------------
-- Internal
--------------------------------------------------------------------------------

local function OnSubscriptionStatusChanged(Player: Player, SubscriptionId: string)

end

local function OnGamepassPurchaseFinished(Player, Id, WasBought)
    if WasBought then
        table.insert(PlayerGamepasses[Player.UserId], Id)
        local Callbacks = GamepassCallbacks[Id]

        if Callbacks then
            for _, Callback in Callbacks do
                task.spawn(Callback, Player)
            end
        end
    end
end

local function OnPlayerAdded(Player: Player)
    local ThreadsWaitingForPlayer = {} :: {thread}
    local Gamepasses = {}

    PlayersLoading[Player.UserId] = ThreadsWaitingForPlayer
    PlayerGamepasses[Player.UserId] = Gamepasses
    PlayerWriteQueues[Player.UserId] = {}

    for GamepassId in GamepassCallbacks do
        local IsOwned = MarketplaceService:UserOwnsGamePassAsync(Player.UserId, GamepassId)

        if IsOwned then
            table.insert(Gamepasses, GamepassId)
        end
    end

    for _, Thread in ThreadsWaitingForPlayer do
        if Player:IsDescendantOf(Players) then
            task.spawn(Thread, true)
        else
            task.spawn(Thread, false)
        end
    end

    PlayersLoading[Player.UserId] = nil
end

local function OnPlayerRemoving(Player: Player)
    local ThreadsWaitingForPlayer = PlayersLoading[Player.UserId]

    if ThreadsWaitingForPlayer and #ThreadsWaitingForPlayer ~= 0 then
        for _, Thread in ThreadsWaitingForPlayer do
            task.spawn(Thread, false)
        end
    end

    PlayerWriteQueues[Player.UserId] = nil
    PlayerGamepasses[Player.UserId] = nil
    PlayersLoading[Player.UserId] = nil
end

local function ProcessProduct(ProductId: number, UserId: number, Key: string, ReciptInfo: ReciptInfo, Callback: ProductCallback)
    local Sucess, IsPurchaseRecorded = pcall(function(ReciptInfo: ReciptInfo, Key: string, UserId: number, Callback: ProductCallback, ProductId: number)
        local WasRecorded = false

        Datastore:UpdateAsync(Key, function(IsPurchased: boolean): boolean?
            -- Dont write if the purchase was already sucessful
            -- or if the player isn't in game
            if IsPurchased then 
                WasRecorded = true
                return nil
            elseif not PlayerGamepasses[UserId] then
                return nil
            end

            local Sucess, ShouldGrant = pcall(Callback, Players:GetPlayerByUserId(UserId) :: Player, ReciptInfo.PurchaseId, {
                PlaceWhereBought = ReciptInfo.PlaceIdWherePurchased,
                Currency = ReciptInfo.CurrencyType,
                Spent = ReciptInfo.CurrencySpent,
            })

            -- Only write if the Callback was sucessful and detirmined that it should be granted
            if not Sucess or ShouldGrant then
                error(ShouldGrant)
            else
                WasRecorded = true
                return true, table.create(1, UserId)
            end
        end)
        return WasRecorded
    end, ReciptInfo, Key, UserId, Callback, ProductId)

    if not Sucess then
        error(`[Marketer] Processing failed for Product {ProductId}\n\tMessage: {IsPurchaseRecorded}`)
    elseif IsPurchaseRecorded then
        return Enum.ProductPurchaseDecision.PurchaseGranted
    else
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end
end

local function ReciptProcessor(ReciptInfo: ReciptInfo)
    local UserId = ReciptInfo.PlayerId

    -- Checking if the player is in-game using the PlayerGamepasses table
    if not PlayerGamepasses[UserId] then
        return Enum.ProductPurchaseDecision.NotProcessedYet
    end
    local ProductId = ReciptInfo.ProductId
    local Subscription = ProductToSubscriptionMap[ProductId]
    
    if Subscription then
        local DatastoreKey = string.format(Config.ProductKeyFormat, UserId)
        local Sucess, Data = pcall(Datastore.UpdateAsync, Datastore, DatastoreKey, function()
        
        end)

        if not Sucess then
            error(`[Marketer] Could not get Subscription Datastore Key {DatastoreKey}\n\tMessage: {Data}`)
        end
    else
        local Callback = ProductCallbacks[ProductId]

        if not Callback then
            warn(`[Marketer] No callback exists for Product {ProductId}`)
            return Enum.ProductPurchaseDecision.NotProcessedYet
        end

        local DatastoreKey = string.format(
            Config.ProductKeyFormat,
            ProductId, 
            ReciptInfo.PurchaseId,
            UserId
        )
        local Sucess, IsPurchased = pcall(Datastore.GetAsync, Datastore, DatastoreKey)

        if Sucess then
            -- Checking if the player is in-game using the PlayerGamepasses table
            if not PlayerGamepasses[UserId] then
                return Enum.ProductPurchaseDecision.NotProcessedYet
            end

            if IsPurchased then
                return Enum.ProductPurchaseDecision.PurchaseGranted
            else
                return ProcessProduct(ProductId, UserId, DatastoreKey, ReciptInfo, Callback)
            end
        else
            error(`[Marketer] Could not get Product Datastore Key {DatastoreKey}\n\tMessage: {IsPurchased}`)
        end
    end

    return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function Init(NewConfig: Config?)
    if IsServer then
        if NewConfig then
            Config.SubscriptionKeyFormat = NewConfig.SubscriptionKeyFormat or Config.SubscriptionKeyFormat
            Config.ProductKeyFormat = NewConfig.ProductKeyFormat or Config.ProductKeyFormat
            Config.DatastoreName = NewConfig.DatastoreName or Config.DatastoreName
        end
        Datastore = DatastoreService:GetDataStore(Config.DatastoreName, "V1")

        Players.UserSubscriptionStatusChanged:Connect(OnSubscriptionStatusChanged)
        MarketplaceService.ProcessReceipt = ReciptProcessor
        Players.PlayerRemoving:Connect(OnPlayerRemoving)
        Players.PlayerAdded:Connect(OnPlayerAdded)

        for _, Player in Players:GetPlayers() do
            if not PlayerGamepasses[Player.UserId] then
                task.spawn(OnPlayerAdded, Player)
            end
        end
    else
        local Player = Players.LocalPlayer
        OnPlayerAdded(Player)
    end

    MarketplaceService.PromptGamePassPurchaseFinished:Connect(OnGamepassPurchaseFinished)
end

--------------------------------------------------------------------------------
-- Subscriptions
--------------------------------------------------------------------------------

local function Subscription_Base_PlayerUnsubscribed(self: BaseSubscription, Callback: (Player: Player, ExpirationReason: Enum.SubscriptionExpirationReason) -> ())

end

local function Subscription_Base_PlayerSubscribed(self: BaseSubscription, Callback: (Player: Player) -> ())

end

local function Subscription_Base_IsSubscribed(self: BaseSubscription, PlayerOrUserId: Player | number)
    if typeof(PlayerOrUserId) == "Instance" then
        return table.find(self.Subscribers, PlayerOrUserId) ~= nil
    else

    end
end

local function Subscription_Base_GetHistory(self: BaseSubscription, PlayerOrUserId: Player | number)

end

local function Subscription_Base_GetState(self: BaseSubscription, PlayerOrUserId: Player | number)

end

local RobuxSubscription = {
	PlayerUnsubscribed = Subscription_Base_PlayerUnsubscribed,
	PlayerSubscribed = Subscription_Base_PlayerSubscribed,
	IsSubscribed = Subscription_Base_IsSubscribed,	
	GetHistory = Subscription_Base_GetHistory,	
	GetState = Subscription_Base_GetState,
    __type = "RobuxSubscription",
}
RobuxSubscription.__index = RobuxSubscription
table.freeze(RobuxSubscription)

local DualSubscription = {
	PlayerUnsubscribed = Subscription_Base_PlayerUnsubscribed,
	PlayerSubscribed = Subscription_Base_PlayerSubscribed,
	IsSubscribed = Subscription_Base_IsSubscribed,	
	GetHistory = Subscription_Base_GetHistory,	
	GetState = Subscription_Base_GetState,
    __type = "DualSubscription",
}
DualSubscription.__index = DualSubscription
table.freeze(DualSubscription)

local USDSubscription = {
	PlayerUnsubscribed = Subscription_Base_PlayerUnsubscribed,
	PlayerSubscribed = Subscription_Base_PlayerSubscribed,
	IsSubscribed = Subscription_Base_IsSubscribed,	
	GetHistory = Subscription_Base_GetHistory,	
	GetState = Subscription_Base_GetState,
    __type = "USDSubscription",
}
USDSubscription.__index = USDSubscription
table.freeze(USDSubscription)

local function GetOrCreateDualSubscription(Name: string, SubscriptionId: string?): DualSubscription?
    for _, Subscription in Subscriptions do
        if Subscription.Name == Name and Subscription.__type = "DualSubscription" then
            return Subscription
        end
    end
    if not SubscriptionId then
        error(`[Marketer] No USDSubscription found with Name {Name}, and no SubscriptionId was provided to create a subscription`)
    end
    local Sucess, Info = pcall(MarketplaceService.GetSubscriptionProductInfoAsync, MarketplaceService, SubscriptionId)
    
    if not Sucess then
        local Retrys = 0

        repeat
            Sucess, Info = pcall(MarketplaceService.GetSubscriptionProductInfoAsync, MarketplaceService, SubscriptionId)
            Retrys += 1
        until Sucess or Retrys > 20
    end

    if Sucess then
        Info.ProviderName = Info.SubscriptionProviderName
        Info.Period = Info.SubscriptionPeriod
        Info.SubscriptionId = SubscriptionId
        Info.SubscriptionProviderName = nil
        Info.Icon = Info.IconImageAssetId
        Info.SubscriptionPeriod = nil
        Info.IconImageAssetId = nil
        Info.IsForSale = nil

        local Subscription = setmetatable(Info, DualSubscription)
        table.insert(Subscriptions, Subscription)
        return Subscription :: any
    else
        warn(`[Marketer] Could not fetch Subscription Info for Subscription {Name}\n\tMessage: {Info}`)
        return nil
    end
end

local function GetOrCreateUSDSubscription(Name: string, SubscriptionId: string?)
    for _, Subscription in Subscriptions do
        if Subscription.Name == Name and Subscription.__type = "USDSubscription" then
            return Subscription
        end
    end
    if not SubscriptionId then
        error(`[Marketer] No USDSubscription found with Name {Name}, and no SubscriptionId was provided to create a subscription`)
    end
    local Sucess, Info = pcall(MarketplaceService.GetSubscriptionProductInfoAsync, MarketplaceService, SubscriptionId)
    
    if not Sucess then
        local Retrys = 0

        repeat
            Sucess, Info = pcall(MarketplaceService.GetSubscriptionProductInfoAsync, MarketplaceService, SubscriptionId)
            Retrys += 1
        until Sucess or Retrys > 20
    end

    if Sucess then
        Info.ProviderName = Info.SubscriptionProviderName
        Info.Period = Info.SubscriptionPeriod
        Info.SubscriptionId = SubscriptionId
        Info.SubscriptionProviderName = nil
        Info.Icon = Info.IconImageAssetId
        Info.SubscriptionPeriod = nil
        Info.IconImageAssetId = nil
        Info.IsForSale = nil

        local Subscription = setmetatable(Info, USDSubscription)
        table.insert(Subscriptions, Subscription)
        return Subscription :: any
    else
        warn(`[Marketer] Could not fetch Subscription Info for Subscription {Name}\n\tMessage: {Info}`)
        return nil
    end
end

local function GetOrCreateRobuxSubscription(Name: string, ProductId: number?): RobuxSubscription
    for _, Subscription in Subscriptions do
        if Subscription.Name == Name and Subscription.__type = "RobuxSubscription" then
            return Subscription
        end
    end
end

--------------------------------------------------------------------------------
-- Exported Methods
--------------------------------------------------------------------------------

local function CanGetPlayerData(Player: Player)
    local ThreadsWaitingForPlayer = PlayersLoading[Player.UserId]

    if ThreadsWaitingForPlayer then
        table.insert(ThreadsWaitingForPlayer, coroutine.running())
        return coroutine.yield()
    else
        return true
    end
end

local function GetSubscriptionForProduct(Id: number): (RobuxSubscription | DualSubscription)?
    return ProductToSubscriptionMap[Id]
end

local function OnGamepassPurchased(Id: number, Callback: (Player: Player) -> ())
    local CallbackList = GamepassCallbacks[Id]
    local Index

    if CallbackList then
        table.insert(CallbackList, Callback)
        Index = #CallbackList
    else
        GamepassCallbacks[Id] = table.create(1, Callback)
        Index = 1
    end
    
    return function()
        SwapRemove(GamepassCallbacks, Index)
    end
end

local function OnProductPurchased(Id: number, Callback: ProductCallback)
    local Value = ProductCallbacks[Id]

    if not Value then
        ProductCallbacks[Id] = Callback
    else
        error(`[Marketer] Callback already exists for Product {Id}\n\tExistingCallback{string.sub(tostring(Value), 9)}`)
    end
end

local function DoesOwnGamepass(Id: number, Player: Player)
    local CanGetPlayerData = CanGetPlayerData(Player)

    if CanGetPlayerData then
        return table.find(PlayerGamepasses[Player.UserId], Id) ~= nil
    else
        return false
    end
end

local Exports = table.freeze {
    GetSubscriptionForProduct = GetSubscriptionForProduct,
    OnGamepassPurchased = OnGamepassPurchased,
    OnProductPurchased = OnProductPurchased,
    Init = Init :: (Config: Config?) -> (),
    DoesOwnGamepass = DoesOwnGamepass,
    Config = Config :: typeof(Config),

    Subscription = table.freeze {
        Robux = GetOrCreateRobuxSubscription,
    	Dual = GetOrCreateDualSubscription,
        USD = GetOrCreateUSDSubscription,
	Tiered = nil,
    },
}

return Exports
