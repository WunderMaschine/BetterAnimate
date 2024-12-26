local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CoreConfig = {
	DebugHumanoidLoadAnimation = script:GetAttribute("DebugHumanoidLoadAnimation"),
	ScaleDampeningAttribute = "ScaleDampeningPercent",
	DefaultHipHeight = 2,
	DefaultFadeTime = 0.3,
	MinWeight = 1e-4,
	BaseRunSpeed = 16 / 1.25,
	BaseWalkSpeed = 8 / 1.25,
}

local localPlayer = Players.LocalPlayer
local charContainer: Instance = assert(script.Parent, "No parent!")
local charModel = assert(if charContainer:IsA("Model") then charContainer else nil, "Parent must be Model!")

local charHumanoid = assert(charModel:FindFirstChildOfClass("Humanoid"), "No Humanoid found!")
local charAnimator = charHumanoid:FindFirstChildOfClass("Animator")

if not charAnimator then
	if RunService:IsServer() then
		charAnimator = Instance.new("Animator")
		assert(charAnimator).Parent = charHumanoid
	else
		charAnimator = charHumanoid :: any
	end
end

local OverParams = OverlapParams.new()
OverParams.FilterDescendantsInstances = { charModel }
OverParams.MaxParts = 5

type AnimDef = { Id: string, Weight: number, Animation: Animation?, Track: AnimationTrack? }
type AnimSet = { TotalWeight: number, [number]: AnimDef }
type TrackController = {
	Speed: number?,
	Weight: number?,
	FadeTime: number?,
	TimePosition: number?,
	Priority: Enum.AnimationPriority?,
	CustomSet: AnimSet,
	DefaultSet: AnimSet,
	ActiveTrack: AnimationTrack?,
}
type Locomotion = { Velocity: Vector2, Speed: number }
type StateCallback = { [Enum.HumanoidStateType]: () -> () }

local Core = {
	Controllers = {} :: { [string]: TrackController },
	DefaultAnimations = {} :: { [string]: { AnimDef } },
	EmoteFlags = {} :: { [string]: boolean },
	StateCallbacks = {} :: StateCallback,
	LoopMap = {} :: { [AnimationTrack]: boolean },
	MotionData = {} :: { [string]: Locomotion },
}

Core.EmoteFlags = {
	wave = false,
	point = false,
	dance = true,
	dance2 = true,
	dance3 = true,
	laugh = false,
	cheer = false,
}

Core.DefaultAnimations = {
	idle = {
		{ Id = "rbxassetid://507766666", Weight = 1 },
		{ Id = "rbxassetid://507766951", Weight = 1 },
		{ Id = "rbxassetid://507766388", Weight = 9 },
	},
	walk = {
		{ Id = "rbxassetid://507777826", Weight = 10 },
	},
	run = {
		{ Id = "rbxassetid://507767714", Weight = 10 },
	},
	swim = {
		{ Id = "rbxassetid://507784897", Weight = 10 },
	},
	swimidle = {
		{ Id = "rbxassetid://507785072", Weight = 10 },
	},
	jump = {
		{ Id = "rbxassetid://507765000", Weight = 10 },
	},
	fall = {
		{ Id = "rbxassetid://507767968", Weight = 10 },
	},
	climb = {
		{ Id = "rbxassetid://507765644", Weight = 10 },
	},
	sit = {
		{ Id = "rbxassetid://2506281703", Weight = 10 },
	},
	toolnone = {
		{ Id = "rbxassetid://507768375", Weight = 10 },
	},
	toolslash = {
		{ Id = "rbxassetid://522635514", Weight = 10 },
	},
	toollunge = {
		{ Id = "rbxassetid://522638767", Weight = 10 },
	},
	wave = {
		{ Id = "rbxassetid://507770239", Weight = 10 },
	},
	point = {
		{ Id = "rbxassetid://507770453", Weight = 10 },
	},
	dance = {
		{ Id = "rbxassetid://507771019", Weight = 10 },
		{ Id = "rbxassetid://507771955", Weight = 10 },
		{ Id = "rbxassetid://507772104", Weight = 10 },
	},
	dance2 = {
		{ Id = "rbxassetid://507776043", Weight = 10 },
		{ Id = "rbxassetid://507776720", Weight = 10 },
		{ Id = "rbxassetid://507776879", Weight = 10 },
	},
	dance3 = {
		{ Id = "rbxassetid://507777268", Weight = 10 },
		{ Id = "rbxassetid://507777451", Weight = 10 },
		{ Id = "rbxassetid://507777623", Weight = 10 },
	},
	laugh = {
		{ Id = "rbxassetid://507770818", Weight = 10 },
	},
	cheer = {
		{ Id = "rbxassetid://507770677", Weight = 10 },
	},
}

Core.MotionData = {
	run = {
		Speed = CoreConfig.BaseRunSpeed,
		Velocity = Vector2.yAxis * CoreConfig.BaseRunSpeed,
	},
	walk = {
		Speed = CoreConfig.BaseWalkSpeed,
		Velocity = Vector2.yAxis * CoreConfig.BaseWalkSpeed,
	},
}

local function makeAnimSet(): AnimSet
	return { TotalWeight = 0 }
end

local function getSignedAngle(vecA: Vector2, vecB: Vector2)
	return -math.atan2(vecA.X * vecB.Y - vecA.Y * vecB.X, vecA.X * vecB.X + vecA.Y * vecB.Y)
end

local function bindStateCallback(stType: Enum.HumanoidStateType, cb: () -> ())
	Core.StateCallbacks[stType] = cb
end

local function fetchTrackController(ctrlName: string): TrackController
	local ctrl = Core.Controllers[ctrlName]
	return assert(ctrl, "Unknown animation name: " .. tostring(ctrlName))
end

local function fetchNumericValue(obj: Instance, k: string): number?
	local val = obj:FindFirstChild(k)
	if val and val:IsA("NumberValue") then
		return val.Value
	end
	local attr = obj:GetAttribute(k)
	if typeof(attr) == "number" then
		return attr
	end
	return nil
end

local function deriveHeightScale(): number
	if not charHumanoid.AutomaticScalingEnabled then
		return 1
	end
	local damp = fetchNumericValue(script, CoreConfig.ScaleDampeningAttribute)
	if damp then
		return 1 + (charHumanoid.HipHeight - CoreConfig.DefaultHipHeight) * damp / CoreConfig.DefaultHipHeight
	else
		return charHumanoid.HipHeight / CoreConfig.DefaultHipHeight
	end
end

local function fetchTimePosition(ctrl: TrackController): number?
	local trk = ctrl.ActiveTrack
	if trk and trk.IsPlaying and trk.WeightTarget > CoreConfig.MinWeight then
		return trk.TimePosition
	end
	return
end

local function initializeAnimation(def: AnimDef): AnimationTrack
	if not def.Track then
		local anim = def.Animation
		if not anim then
			anim = Instance.new("Animation")
			assert(anim)
			anim.AnimationId = assert(def.Id)
			def.Animation = anim
		end
		local loader = if CoreConfig.DebugHumanoidLoadAnimation then charHumanoid :: any else charAnimator
		local track = loader:LoadAnimation(assert(anim))
		track.Priority = Enum.AnimationPriority.Core
		track.DidLoop:Connect(function()
			Core.LoopMap[track] = true
		end)
		def.Track = track
	end
	return assert(def.Track)
end

local function locateAnimSetFor(customAnim: Animation): (AnimSet?, string?)
	local setParent = customAnim.Parent
	if setParent and setParent:IsA("StringValue") then
		if setParent.Parent ~= script then
			return
		end
		local setId = setParent.Name
		local ctrl = Core.Controllers[setId]
		if not ctrl then
			ctrl = { DefaultSet = makeAnimSet(), CustomSet = makeAnimSet() }
			Core.Controllers[setId] = ctrl
		end
		return ctrl.CustomSet, setId
	end
	return
end

local function cycleAnimation(ctrl: TrackController): (AnimationTrack?, boolean?)
	local targetSet = if #ctrl.CustomSet == 0 then ctrl.DefaultSet else ctrl.CustomSet
	if #targetSet == 1 then
		local single = targetSet[1]
		return initializeAnimation(single), false
	elseif #targetSet == 0 then
		return nil, nil
	end
	local tot = assert(targetSet.TotalWeight)
	local r = math.random() * tot
	local curr = 0
	local idx = 1
	while curr < tot do
		local item = assert(targetSet[idx])
		local nextVal = curr + item.Weight
		if r >= curr and r < nextVal then
			return initializeAnimation(item), true
		end
		idx += 1
		curr = nextVal
	end
	return nil, nil
end

local function isEmotePossible()
	if charHumanoid.MoveDirection ~= Vector3.zero then
		return false
	end
	if charHumanoid:GetState() ~= Enum.HumanoidStateType.Running then
		return false
	end
	return true
end

local function onAnimationAdded(anim: Instance)
	if anim:IsA("Animation") then
		local animSet, setId = locateAnimSetFor(anim)
		if animSet then
			local linVel = anim:GetAttribute("LinearVelocity")
			local w = fetchNumericValue(anim, "Weight") or 1
			local newDef: AnimDef = {
				Id = anim.AnimationId,
				Animation = anim,
				Weight = w,
			}
			animSet.TotalWeight += w
			initializeAnimation(newDef)
			if setId and typeof(linVel) == "Vector2" then
				Core.MotionData[setId] = { Velocity = linVel, Speed = linVel.Magnitude }
			end
			table.insert(animSet, newDef)
		end
	end
end

local function onAnimationRemoving(anim: Instance)
	if anim:IsA("Animation") then
		local animSet = locateAnimSetFor(anim)
		if animSet then
			local dropIdx: number?
			for i, def in ipairs(animSet) do
				if def.Animation == anim then
					animSet.TotalWeight -= def.Weight
					dropIdx = i
					break
				end
			end
			if dropIdx then
				table.remove(animSet, dropIdx)
			end
		end
	end
end

for id, defs in Core.DefaultAnimations do
	local defaultSet = makeAnimSet()
	for _, singleDef in defs do
		defaultSet.TotalWeight += singleDef.Weight
		table.insert(defaultSet, singleDef)
		initializeAnimation(singleDef)
	end
	Core.Controllers[id] = { DefaultSet = defaultSet, CustomSet = makeAnimSet() }
end

for _, descendant in script:GetDescendants() do
	onAnimationAdded(descendant)
end

script.DescendantAdded:Connect(onAnimationAdded)
script.DescendantRemoving:Connect(onAnimationRemoving)

local normalWalk = 0.5
local normalRun = 1
local toolAnimEvent: string?
local currentEmote: string?
local jumpRecord = 0
local toolAnimClock = 0

local function state_Jumping()
	jumpRecord = os.clock() + 0.4
end

local function state_Freefall()
	local t = os.clock()
	local ctrl = if t < jumpRecord then fetchTrackController("jump") else fetchTrackController("fall")
	ctrl.Weight = 1
	ctrl.FadeTime = 0.1
end

local function state_Sit()
	local sitCtrl = fetchTrackController("sit")
	sitCtrl.FadeTime = 0.4
	sitCtrl.Weight = 1
	sitCtrl.Speed = 0
end

local function state_Climb()
	local root = charHumanoid.RootPart
	local spd = 0
	if root then
		spd = root.AssemblyLinearVelocity.Y / 5
	end
	local climbCtrl = fetchTrackController("climb")
	climbCtrl.Speed = spd
	climbCtrl.Weight = 1
end

local function state_Swim()
	local root = charHumanoid.RootPart
	local spd = 0
	if root then
		spd = root.AssemblyLinearVelocity.Magnitude
	end
	local swimCtrl = fetchTrackController("swim")
	local swimIdleCtrl = fetchTrackController("swimidle")
	swimCtrl.FadeTime = 0.4
	swimIdleCtrl.FadeTime = 0.4
	if spd > 1 then
		swimCtrl.Speed = spd / 10
		swimCtrl.Weight = 1
	else
		swimIdleCtrl.Weight = 1
	end
end

local function state_Run()
	local root = charHumanoid.RootPart
	local localVel = Vector2.zero
	local speed = 0
	if root then
		local rootHalf = root.Size.Y / 2
		local hh = charHumanoid.HipHeight
		local groundPos = root.Position - (Vector3.yAxis * (hh + rootHalf))
		local parts = workspace:GetPartBoundsInRadius(groundPos, 1, OverParams)
		local vel = root.AssemblyLinearVelocity
		local doneRoots = {}
		for _, prt in ipairs(parts) do
			local rootOf = if prt:IsA("BasePart") then prt.AssemblyRootPart else nil
			if rootOf and not doneRoots[rootOf] then
				vel -= rootOf:GetVelocityAtPosition(groundPos)
				doneRoots[rootOf] = true
			end
		end
		local cf = root.CFrame
		local rightV = cf.RightVector:Dot(vel)
		local forwardV = cf.LookVector:Dot(vel)
		localVel = Vector2.new(rightV, forwardV)
		speed = localVel.Magnitude
	end
	local scale = deriveHeightScale()
	local runRatio = (speed / CoreConfig.BaseRunSpeed) / scale
	if speed > scale / 2 then
		local runBlend = (runRatio - normalWalk) / (normalRun - normalWalk)
		local runAnimSpeed = math.max(1, math.log(runBlend + 1))
		local runAnimWeight = math.clamp(runBlend, CoreConfig.MinWeight, 1)
		local walkAnimWeight = math.clamp(
			if runAnimWeight == CoreConfig.MinWeight then runRatio / normalWalk else 1 - runBlend,
			CoreConfig.MinWeight,
			1
		)
		local inMotion = {}
		local allLow, allHigh = false, false
		local lowX, lowY, highX, highY = false, false, false, false

		for id, mData in Core.MotionData do
			if localVel:Dot(mData.Velocity) > 0 then
				inMotion[id] = mData
			end
			if not allLow then
				lowX = lowX or mData.Velocity.X < 0
				lowY = lowY or mData.Velocity.Y < 0
				allLow = lowX and lowY
			end
			if not allHigh then
				highX = highX or mData.Velocity.X > 0
				highY = highY or mData.Velocity.Y > 0
				allHigh = highX and highY
			end
		end

		if allLow and allHigh then
			local topPos = 0
			local runWeights, runTotal = {}, 0
			local walkWeights, walkTotal = {}, 0

			for mId, dt in inMotion do
				local angle = getSignedAngle(localVel, dt.Velocity)
				local wgt = math.clamp(1 - math.abs(angle), 0, 1)
				local distRun = math.abs(dt.Speed - CoreConfig.BaseRunSpeed)
				local distWalk = math.abs(dt.Speed - CoreConfig.BaseWalkSpeed)
				if distRun < distWalk then
					runWeights[mId] = wgt
					runTotal += wgt
				else
					walkWeights[mId] = wgt
					walkTotal += wgt
				end
				local c = fetchTrackController(mId)
				local pos = fetchTimePosition(c)
				if pos then
					topPos = math.max(topPos, pos)
				end
			end
			for runId, w in runWeights do
				local rCtrl = fetchTrackController(runId)
				local calcW = (w / runTotal) * runAnimWeight
				rCtrl.Weight = math.clamp(calcW, CoreConfig.MinWeight, 1)
				rCtrl.TimePosition = topPos
				rCtrl.Speed = runAnimSpeed
			end
			for walkId, w in walkWeights do
				local wCtrl = fetchTrackController(walkId)
				local calcW = (w / walkTotal) * walkAnimWeight
				wCtrl.Weight = math.clamp(calcW, CoreConfig.MinWeight, 1)
				wCtrl.TimePosition = topPos
			end
		else
			local runCtrl = fetchTrackController("run")
			runCtrl.Weight = runAnimWeight
			runCtrl.Speed = runAnimSpeed

			local walkCtrl = fetchTrackController("walk")
			walkCtrl.Weight = walkAnimWeight
		end
	else
		local idleCtrl = fetchTrackController("idle")
		idleCtrl.Weight = 1
	end
end

local function handleEmote(anim: Animation)
	if typeof(anim) ~= "Instance" then
		return false
	end
	if not anim:IsA("Animation") then
		return false
	end
	if not isEmotePossible() then
		return false
	end
	local assetId: string? = anim.AnimationId:match("%d+$")
	if not assetId then
		return false
	end
	local idKey = "emote_" .. assert(assetId)
	local existing = Core.Controllers[idKey]
	if not existing then
		existing = { DefaultSet = makeAnimSet(), CustomSet = makeAnimSet() }
		table.insert(existing.DefaultSet, {
			Id = "rbxassetid://" .. assetId,
			Animation = anim,
			Weight = 1,
		})
		Core.Controllers[idKey] = existing
	end
	currentEmote = idKey
	return true
end

local function handleChat(msg: string)
	local maybeEmote
	if msg:sub(1, 3) == "/e " then
		maybeEmote = msg:sub(4)
	elseif msg:sub(1, 7) == "/emote " then
		maybeEmote = msg:sub(8)
	end
	if Core.EmoteFlags[maybeEmote] ~= nil and isEmotePossible() then
		currentEmote = maybeEmote
	end
end

charHumanoid.Jumping:Connect(state_Jumping)
if localPlayer then
	localPlayer.Chatted:Connect(handleChat)
end

task.spawn(function()
	local binder = script:WaitForChild("PlayEmote", math.huge)
	if binder and binder:IsA("BindableFunction") then
		binder.OnInvoke = handleEmote
	end
end)

bindStateCallback(Enum.HumanoidStateType.Seated, state_Sit)
bindStateCallback(Enum.HumanoidStateType.Running, state_Run)
bindStateCallback(Enum.HumanoidStateType.Climbing, state_Climb)
bindStateCallback(Enum.HumanoidStateType.Freefall, state_Freefall)
bindStateCallback(Enum.HumanoidStateType.Swimming, state_Swim)

assert(charAnimator)
for _, oldTrack: AnimationTrack in charAnimator:GetPlayingAnimationTracks() do
	oldTrack:Stop(0)
	oldTrack:Destroy()
end

local function refreshToolAnimation(tool: Tool)
	local now = os.clock()
	local target = "toolnone"
	local animCheck = tool:FindFirstChild("toolanim")
	if animCheck and animCheck:IsA("StringValue") then
		toolAnimEvent = animCheck.Value
		toolAnimClock = now + 0.3
		animCheck.Parent = nil
	end
	if now < toolAnimClock then
		if toolAnimEvent == "Slash" then
			target = "toolslash"
		elseif toolAnimEvent == "Lunge" and not charHumanoid.Sit then
			target = "toollunge"
		end
	elseif toolAnimEvent then
		toolAnimEvent = nil
	end
	local ctrl = fetchTrackController(target)
	ctrl.Priority = Enum.AnimationPriority.Action
	ctrl.FadeTime = 0.1
	ctrl.Weight = 1
end

local function processAllAnimations()
	local possibleTool = charModel:FindFirstChildWhichIsA("Tool")
	if possibleTool and possibleTool.RequiresHandle then
		refreshToolAnimation(possibleTool)
	end
	if currentEmote and isEmotePossible() then
		local emoteCtrl = fetchTrackController(currentEmote)
		emoteCtrl.Weight = 1
	else
		local st = charHumanoid:GetState()
		local cb = Core.StateCallbacks[st]
		if cb then cb() end
		currentEmote = nil
	end

	for _, ctrl in Core.Controllers do
		local spd, wgt, fade, trk = ctrl.Speed, ctrl.Weight, ctrl.FadeTime, ctrl.ActiveTrack
		if spd or wgt then
			local valid = (trk and trk.IsPlaying) and true or false
			local newTrack: AnimationTrack?
			local rollFlag: boolean?

			if valid and trk and Core.LoopMap[trk] then
				newTrack, rollFlag = cycleAnimation(ctrl)
				if rollFlag then
					valid = false
				end
				Core.LoopMap[trk] = nil
			end

			if not valid then
				if trk and trk ~= newTrack then
					trk:Stop(fade or CoreConfig.DefaultFadeTime)
				end
				trk = newTrack or cycleAnimation(ctrl)
				ctrl.ActiveTrack = trk
			end

			if not trk then
				continue
			end

			if trk.IsPlaying then
				if wgt then
					ctrl.Weight = nil
					if wgt == CoreConfig.MinWeight and trk.WeightTarget ~= CoreConfig.MinWeight then
						trk:AdjustWeight(CoreConfig.MinWeight, fade or CoreConfig.DefaultFadeTime)
					elseif math.abs(wgt - trk.WeightTarget) > 0.01 then
						trk:AdjustWeight(wgt, fade or CoreConfig.DefaultFadeTime)
					end
				end
				if spd then
					ctrl.Speed = nil
					if math.abs(spd - trk.Speed) > 0.01 and trk.WeightTarget > CoreConfig.MinWeight then
						trk:AdjustSpeed(spd)
					end
				end
				if ctrl.Priority then
					trk.Priority = ctrl.Priority
					ctrl.Priority = nil
				end
				if ctrl.TimePosition then
					trk.TimePosition = ctrl.TimePosition
				end
			else
				trk:Play(fade or CoreConfig.DefaultFadeTime, wgt or 1, spd or 1)
				trk.TimePosition = ctrl.TimePosition or 0
			end

			if ctrl.TimePosition then
				ctrl.TimePosition = nil
			end
		elseif trk and trk.IsPlaying then
			trk:Stop(fade or CoreConfig.DefaultFadeTime)
		end
		if fade then
			ctrl.FadeTime = nil
		end
	end
end

RunService.Heartbeat:Connect(processAllAnimations)