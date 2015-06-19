ATC_TARGET_DECELERATION = 1.20 -- meters/second/second
ATC_REACTION_TIME = 2.5 -- seconds
MPS_TO_MPH = 2.23694 -- Meters/Second to Miles/Hour
MPH_TO_MPS = 1.0 / MPS_TO_MPH
MPH_TO_MiPS = 0.000277777778 -- Miles/Hour to Miles/Second
MI_TO_M = 1609.34 -- Miles to Meters
M_TO_MI = 1.0 / MI_TO_M -- Meters to Miles
ATC_WARN_OFF = 0.0
ATC_WARN_CONSTANT = 1.0
ATC_WARN_INTERMITTENT = 2.0
DISPLAY_SPEEDS = { 0, 15, 25, 35, 45, 55, 70 }
NUM_DISLPAY_SPEEDS = 7
EST_REACTION_TIME = 3 -- Estimated reaction time of the driver for speed drops
ACCEL_TIME = 2 -- The amount of time it takes to go from full power to full brake (with jerk limit)

atcSigDirection = 0.0
gLastSigDist = 0.0
gLastSigDistTime = 0.0
gBrakeApplication = false
gBrakeTime = 0.0
gAlertAcknowledged = true
gTimeSinceSpeedIncrease = 0.0
gLastSpeedLimit = 0.0

function getBrakingDistance(vF, vI, a)
	return ((vF * vF) - (vI * vI)) / (2 * a)
end

function getStoppingSpeed(vI, a, d)
	return math.sqrt(math.max((vI * vI) + (2 * a * d), 0.0))
end

function SetATCWarnMode(mode)
	Call("*:SetControlValue", "ATCWarnMode", 0, mode)
end

function getSpeedLimitAbove(speed)
	for i = 1, NUM_DISLPAY_SPEEDS do
		if DISPLAY_SPEEDS[i] >= speed then
			return DISPLAY_SPEEDS[i]
		end
	end
	return DISPLAY_SPEEDS[NUM_DISPLAY_SPEEDS]
end

function getSpeedLimitBelow(speed)
	for i = NUM_DISLPAY_SPEEDS, 1, -1 do
		if DISPLAY_SPEEDS[i] <= speed then
			return DISPLAY_SPEEDS[i]
		end
	end
	return DISPLAY_SPEEDS[1]
end

function UpdateATC(interval)
	local targetSpeed, trainSpeed, enabled, throttle
	local spdType, spdLimit, spdDist, spdBuffer
	local sigResult, sigState, sigDist, sigAspect

	targetSpeed = Call("*:GetCurrentSpeedLimit")
	trackSpeed = targetSpeed
	trainSpeed = math.abs(TrainSpeed) * MPH_TO_MPS
	enabled = Call("*:GetControlValue", "ATCEnabled", 0) > 0
	reactionTimeDistance = trackSpeed * (EST_REACTION_TIME + ACCEL_TIME)
	stoppingDistance = getBrakingDistance(0, math.max(trainSpeed, 0.01), -ATC_TARGET_DECELERATION)
	
	spdType, spdLimit, spdDist = Call("*:GetNextSpeedLimit", 0)
	sigResult, sigState, sigDist, sigAspect = Call("*:GetNextRestrictiveSignal", 0)
	
	if (spdLimit ~= targetSpeed and spdType > 0) then
		--debugPrint("Next speed limit drop: " .. tostring(spdLimit * MPS_TO_MPH) .. " MPH in " .. tostring(spdDist) .. " m (t: " .. tostring(spdType) .. ")")
	end
	
	searchCount = 0
	while (sigResult > 0 and sigAspect >= 20 and searchCount < 10) do -- Signal aspects >20 are for wayside communication, not for path clearance
		sigResult, sigState, sigDist, sigAspect = Call("*:GetNextRestrictiveSignal", 0, sigDist + 0.1)
		searchCount = searchCount + 1
	end
	
	if (sigResult < 0) then -- no signal
		sigState = 0
	end
	Call("*:SetControlValue", "ATCAspect", 0, sigState)
	
	if (sigResult > 0 and (sigState == 2 or sigAspect == 3) and (sigDist < stoppingDistance + reactionTimeDistance)) then -- Treat a red signal as "end of track"
		spdType = 0
		spdDist = sigDist
		--debugPrint("Found red signal in " .. tostring(sigDist) .. " m...")
	end
	
	if (spdType == 0) then -- End of line...stop the train
		spdBuffer = (getBrakingDistance(0.0, targetSpeed, -ATC_TARGET_DECELERATION) + reactionTimeDistance)
		Call("*:SetControlValue", "SpeedBuffer", 0, spdBuffer)
		if (spdDist <= spdBuffer) then
			targetSpeed = math.max(getStoppingSpeed(trackSpeed, -ATC_TARGET_DECELERATION, (spdBuffer + 10.0) - spdDist) - 0.25, 6.0 * MPH_TO_MPS)
			if (spdDist <= 50) then
				targetSpeed = math.min(targetSpeed, 6 * MPH_TO_MPS)
			end
			if (spdDist < 10) then
				targetSpeed = 0
			end
		end
	elseif (spdType > 0) then
		searchDist = spdDist + 0.1
		searchCount = 0
		maxSearchDist = reactionTimeDistance + stoppingDistance
		repeat
			if (spdLimit < targetSpeed) then
				spdBuffer = getBrakingDistance(spdLimit, trainSpeed, -ATC_TARGET_DECELERATION) + reactionTimeDistance
				if (spdDist <= spdBuffer) then
					targetSpeed = math.min(targetSpeed, math.max(getStoppingSpeed(trackSpeed, -ATC_TARGET_DECELERATION, spdBuffer - (spdDist - reactionTimeDistance)), spdLimit))
				end
			end
			
			tSpdType, tSpdLimit, tSpdDist = Call("*:GetNextSpeedLimit", 0, searchDist)
			if (tSpdType == 0 or (tSpdType > 0 and tSpdLimit < spdLimit)) then
				spdType, spdLimit, spdDist = tSpdType, tSpdLimit, tSpdDist
			end
			
			searchDist = tSpdDist + 0.1
			searchCount = searchCount + 1
		until (searchDist > maxSearchDist or spdType < 0 or searchCount > 10)
	end
	
	gLastSigDistTime = gLastSigDistTime + interval
	sigType, sigState, sigDist, sigAspect = Call("*:GetNextRestrictiveSignal", atcSigDirection)
	if (sigDist > gLastSigDist and gLastSigDistTime >= 1.0) then
		if (atcSigDirection < 0.5) then
			atcSigDirection = 1
		else
			atcSigDirection = 0
		end
	end
	
	if (gLastSigDistTime >= 1.0) then
		gLastSigDistTime = 0.0
		gLastSigDist = sigDist
	end
	
	targetSpeed = math.floor((targetSpeed * MPS_TO_MPH * 10) + 0.5) / 10 -- Round to nearest 0.1
	
	ATOEnabled = (Call("*:GetControlValue", "ATOEnabled", 0) or -1) > 0.0
	
	if (targetSpeed > gLastSpeedLimit) then
		if (gTimeSinceSpeedIncrease < 1.5) then -- Don't increase speed if it only increases for a split second (this avoids speed limit bugs in the engine)
			gTimeSinceSpeedIncrease = gTimeSinceSpeedIncrease + interval
			targetSpeed = gLastSpeedLimit
		else
			gLastSpeedLimit = targetSpeed
		end
	else
		gTimeSinceSpeedIncrease = 0
	end
	gLastSpeedLimit = targetSpeed
	
	if enabled then
		if (not ATOEnabled) then
			-- The ATC can only display certain speed limits; allow the next lowest one above actual, and driver is responsible for following actual
			if (targetSpeed >= 10) then
				targetSpeed = getSpeedLimitAbove(targetSpeed)
			else -- If it's below 10 (like end of track), we force them to obey it
				if (math.abs(TrainSpeed) > targetSpeed + 1) then
					targetSpeed = getSpeedLimitBelow(targetSpeed)
				else
					targetSpeed = getSpeedLimitAbove(targetSpeed)
				end
			end
		end
	else
		targetSpeed = 70
	end
	
	Call("*:SetControlValue", "ATCRestrictedSpeed", 0, targetSpeed)
	
	-- Following section logic taken from CTA 7000-series RFP spec
	
	throttle = CombinedLever * 2.0 - 1.0
	
	if ((TrainSpeed >= (targetSpeed + 1) or gBrakeApplication) and not ATOEnabled) then
		gAlertAcknowledged = false
		if (gBrakeApplication) then
			Call("*:SetControlValue", "ATCBrakeApplication", 0, 1.0)
			SetATCWarnMode(ATC_WARN_CONSTANT)
			if (trainSpeed < 0.1 and throttle <= -0.99) then
				gBrakeApplication = false
			end
		else
			Call("*:SetControlValue", "ATCBrakeApplication", 0, 0.0)
			if (throttle <= -0.9) then -- 90% brake application
				SetATCWarnMode(ATC_WARN_INTERMITTENT)
			else
				gBrakeTime = gBrakeTime + interval
				if (gBrakeTime >= ATC_REACTION_TIME) then
					gBrakeApplication = true
				end
				SetATCWarnMode(ATC_WARN_CONSTANT)
			end
		end
	else
		Call("*:SetControlValue", "ATCBrakeApplication", 0, 0.0)
		gBrakeTime = 0.0
		SetATCWarnMode(ATC_WARN_OFF)
	end
	
	if (TrainSpeed < (targetSpeed + 1) and throttle <= -0.9) then
		gAlertAcknowledged = true
	end
end