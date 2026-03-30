SugarCaneUnloadingController = CpObject()
SugarCaneUnloadingController.FILL_LEVEL_THRESHOLD = 0.5

function SugarCaneUnloadingController:init(driver, vehicle)
	self.driver = driver
	self.vehicle = vehicle
	self.activeTrailer = nil
	self.trailerStates = {}
end

function SugarCaneUnloadingController:onStart()
	self.activeTrailer = nil
	self.trailerStates = {}
end

function SugarCaneUnloadingController:onStop()
	self.activeTrailer = nil
end

function SugarCaneUnloadingController:isSugarCaneTrailer(object)
	return object and object.spec_dischargeable and object.spec_shovel and object.spec_cylindered
end

function SugarCaneUnloadingController:getTrailers()
	local trailers = {}
	local workTools = self.vehicle and self.vehicle.cp and self.vehicle.cp.workTools
	if not workTools then
		return trailers
	end
	for _, tool in ipairs(workTools) do
		if self:isSugarCaneTrailer(tool) then
			table.insert(trailers, tool)
		end
	end
	return trailers
end

function SugarCaneUnloadingController:getFillLevelPercent(object)
	if not object or not object.spec_dischargeable then
		return 0
	end
	local currentDischargeNode = object:getCurrentDischargeNode()
	if not currentDischargeNode then
		return 0
	end
	return object:getFillUnitFillLevelPercentage(currentDischargeNode.fillUnitIndex) * 100
end

function SugarCaneUnloadingController:hasFill(object)
	return self:getFillLevelPercent(object) > SugarCaneUnloadingController.FILL_LEVEL_THRESHOLD
end

function SugarCaneUnloadingController:getTrailerState(object)
	if not object then
		return nil
	end
	local key = object.rootNode or object
	self.trailerStates[key] = self.trailerStates[key] or {
		state = "PENDING"
	}
	return self.trailerStates[key]
end

function SugarCaneUnloadingController:updateTrailerState(object)
	if not object then
		return
	end
	local state = self:getTrailerState(object)
	if self:hasFill(object) then
		if state.state == "DONE" then
			state.state = "PENDING"
		end
	else
		state.state = "DONE"
		if self.activeTrailer == object then
			self.activeTrailer = nil
		end
	end
end

function SugarCaneUnloadingController:hasPendingTrailerToUnload()
	for _, trailer in ipairs(self:getTrailers()) do
		self:updateTrailerState(trailer)
		if self:hasFill(trailer) then
			return true
		end
	end
	return false
end

function SugarCaneUnloadingController:isTrailerInTrigger(object, objectsInTrigger)
	return object and objectsInTrigger and objectsInTrigger[object] ~= nil
end

function SugarCaneUnloadingController:hasLoadedTrailerInTrigger(objectsInTrigger)
	for object, _ in pairs(objectsInTrigger or {}) do
		if self:isSugarCaneTrailer(object) and self:hasFill(object) then
			return true
		end
	end
	return false
end

function SugarCaneUnloadingController:updateObjectPosition(object, dt, positionIx)
	if not object then
		return false
	end
	local setting = self.driver:getWorkingToolPositionsSetting()
	if not setting or not setting.hasPosition or not setting.hasPosition[positionIx] then
		return false
	end
	local spec = object.spec_cylindered
	if not spec or not spec.cpWorkingToolPos or not spec.cpWorkingToolPos[positionIx] or not setting:isValidSpec(object) then
		return false
	end
	local callback = {
		isDirty = false,
		diff = 0
	}
	for toolIndex, tool in ipairs(spec.movingTools) do
		if object:getIsMovingToolActive(tool) then
			local isRotating, rotDiff = WorkingToolPositionsSetting.checkToolRotation(object, tool, toolIndex, positionIx, dt, setting)
			local isMoving, moveDiff = WorkingToolPositionsSetting.checkToolTranslation(object, tool, toolIndex, positionIx, dt, setting)
			if isRotating or isMoving then
				callback.isDirty = true
				callback.diff = math.max(rotDiff, moveDiff, callback.diff)
			end
		end
	end
	return not callback.isDirty
end

function SugarCaneUnloadingController:updateTransportPositions(dt, exceptObject)
	for _, trailer in ipairs(self:getTrailers()) do
		if trailer ~= exceptObject then
			self:updateObjectPosition(trailer, dt, SugarCaneTrailerToolPositionsSetting.TRANSPORT_POSITION)
		end
	end
end

function SugarCaneUnloadingController:updateUnloadingPositions(dt, activeObject)
	self:updateTransportPositions(dt, activeObject)
	if activeObject and self:isSugarCaneTrailer(activeObject) then
		self:updateObjectPosition(activeObject, dt, SugarCaneTrailerToolPositionsSetting.UNLOADING_POSITION)
	end
end

function SugarCaneUnloadingController:canAttemptUnload(triggerHandler)
	local isNearUnloadPoint = self.driver.course and self.driver.ppc and self.driver.course:hasUnloadPointWithinDistance(self.driver.ppc:getCurrentWaypointIx(), 25)
	return triggerHandler.validFillTypeUnloading and (self.driver:hasTipTrigger() or isNearUnloadPoint)
end

function SugarCaneUnloadingController:getNextActiveTrailer(triggerHandler, preferredObject)
	if preferredObject and self:isTrailerInTrigger(preferredObject, triggerHandler.objectsInTrigger) and self:hasFill(preferredObject) then
		return preferredObject
	end
	if self.activeTrailer and self:isTrailerInTrigger(self.activeTrailer, triggerHandler.objectsInTrigger) and self:hasFill(self.activeTrailer) then
		return self.activeTrailer
	end
	for _, trailer in ipairs(self:getTrailers()) do
		if self:isTrailerInTrigger(trailer, triggerHandler.objectsInTrigger) and self:hasFill(trailer) then
			return trailer
		end
	end
	return nil
end

function SugarCaneUnloadingController:handleTrailerUnloading(object, triggerHandler, dt)
	if not self:isSugarCaneTrailer(object) then
		return
	end
	self:updateTrailerState(object)
	if not self:hasFill(object) then
		return
	end
	if not self:canAttemptUnload(triggerHandler) then
		return
	end
	if not self.driver:areWorkingToolPositionsValid() then
		triggerHandler:resetUnloadingState()
		self.driver:hold()
		return
	end
	local activeTrailer = self:getNextActiveTrailer(triggerHandler, object)
	if activeTrailer ~= object then
		return
	end
	self.activeTrailer = object
	self:updateUnloadingPositions(dt, object)

	local spec = object.spec_dischargeable
	local currentDischargeNode = spec.currentDischargeNode
	if not currentDischargeNode then
		return
	end
	if spec:getCanDischargeToObject(currentDischargeNode) and not triggerHandler:isDriveNowActivated() then
		local state = self:getTrailerState(object)
		state.state = "UNLOADING"
		triggerHandler:setUnloadingState(object, currentDischargeNode.fillUnitIndex, spec:getDischargeFillType(currentDischargeNode))
		triggerHandler:debugSparse(object, "Discharging with sugar cane trailer.")
		object:setDischargeState(Dischargeable.DISCHARGE_STATE_OBJECT)
	end
end
