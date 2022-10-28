
RepairCarSpecialization = {
	prerequisitesPresent = function()
		return true
	end,
	Version = "0.1.0.0",
	Name = "RepairCarSpecialization"
}

print(g_currentModName .. " - init " .. RepairCarSpecialization.Name .. "(Version: " .. RepairCarSpecialization.Version .. ")");

function RepairCarSpecialization.initSpecialization()	local schema = Vehicle.xmlSchema
	g_configurationManager:addConfigurationType("repairCar", g_i18n:getText("configuration_repairCar"), "repairCar", nil, nil, nil, ConfigurationUtil.SELECTOR_MULTIOPTION)
	
	schema:setXMLSpecializationType("RepairCar")

	local baseXmlPath = "vehicle.repairCar.repairCarConfigurations.repairCarConfiguration(?)"

	schema:register(XMLValueType.NODE_INDEX, baseXmlPath .. ".triggerNodes.triggerNode(?)#node", "Trigger node for repair")
	schema:register(XMLValueType.FLOAT, baseXmlPath .. "#repairPerInterval", "Percentag of repaired damage per interval", 0.2)
	schema:register(XMLValueType.INT, baseXmlPath .. "#repairInterval", "miliseconds between repairs", 5000)
	schema:register(XMLValueType.INT, baseXmlPath .. "#repairCostFactor", "factor for repair costs", 1)
	schema:register(XMLValueType.INT, baseXmlPath .. "#fillUnitIndex", "Fill unit index to consume instead of money. Money used when not set")

	schema:setXMLSpecializationType()
end

function RepairCarSpecialization.registerEventListeners(vehicleType)
	SpecializationUtil.registerEventListener(vehicleType, "onLoad", RepairCarSpecialization);
    SpecializationUtil.registerEventListener(vehicleType, "onDelete", RepairCarSpecialization)
end

function RepairCarSpecialization.registerFunctions(vehicleType)
	SpecializationUtil.registerFunction(vehicleType, "repairTriggerCallback", RepairCarSpecialization.repairTriggerCallback);
	SpecializationUtil.registerFunction(vehicleType, "writeToLog", RepairCarSpecialization.writeToLog);
	SpecializationUtil.registerFunction(vehicleType, "startRepairVehicles", RepairCarSpecialization.startRepairVehicles);
end

function RepairCarSpecialization:onLoad(savegame)
	local repairCarConfigurationId = Utils.getNoNil(self.configurations["repairCar"], 1)
	local baseXmlPath = string.format("vehicle.repairCar.repairCarConfigurations.repairCarConfiguration(%d)", repairCarConfigurationId -1)
	
	-- init for server and client here
	self.spec_repairCar = {};
	local spec = self.spec_repairCar;
	spec.debug = false;
	
	if self.isServer then
		spec.triggerNodes = {};
		spec.vehicleInTrigger = {};
		spec.numVehicleInTrigger = 0;
		
		spec.repairPerInterval = self.xmlFile:getValue(baseXmlPath .. "#repairPerInterval", 0.2);
		spec.repairInterval = self.xmlFile:getValue(baseXmlPath .. "#repairInterval", 5000);
		spec.repairCostFactor = self.xmlFile:getValue(baseXmlPath .. "#repairCostFactor", 1);
		spec.fillUnitIndex = self.xmlFile:getValue(baseXmlPath .. "#fillUnitIndex")
		
		if spec.fillUnitIndex ~= nil then
			-- define the costs to calcualte the amount of filltype used
			spec.fillType = self:getFillUnitFirstSupportedFillType(spec.fillUnitIndex);
			spec.fillTypePricePerLiter = g_currentMission.economyManager:getPricePerLiter(spec.fillType)
		end
		
		self.xmlFile:iterate(baseXmlPath .. ".triggerNodes.triggerNode", 
			function (index, triggerKey)
				local triggerNode = self.xmlFile:getValue(triggerKey .. "#node", nil, self.components, self.i3dMappings);
				table.insert(spec.triggerNodes, triggerNode);
				if triggerNode ~= nil then
					if not CollisionFlag.getHasFlagSet(triggerNode, CollisionFlag.VEHICLE) then
						Logging.error("Missing collision mask bit '%d'. Please add this bit to trigger node '%s'", CollisionFlag.getBit(CollisionFlag.VEHICLE), I3DUtil.getNodePath(triggerNode))
					else
						addTrigger(triggerNode, "repairTriggerCallback", self);
					end
				end
			end
		)
		
		if #spec.triggerNodes == 0 then
			Logging.xmlError(self.xmlFile, "No valid trigger node found");
		end
	end
end

function RepairCarSpecialization:onDelete()
	local spec = self.spec_repairCar;
	for _, triggerNode in pairs(spec.triggerNodes) do
		removeTrigger(triggerNode);
	end
end

function RepairCarSpecialization:writeToLog(onlyInDebug, value)
	local spec = self.spec_repairCar;
	
	if (onlyInDebug and spec.debug)then
		print("Debug: " .. tostring(value));
	end
	
	if not onlyInDebug then
		print("Info: " .. tostring(value));
	end
end

function RepairCarSpecialization:repairTriggerCallback(triggerId, otherActorId, onEnter, onLeave, onStay, otherShapeId)
	local spec = self.spec_repairCar;
	self:writeToLog(true, "repairTriggerCallback called");
	self:writeToLog(true, "triggerId:" .. tostring(triggerId) .. " otherActorId:" .. tostring(otherActorId) .. " otherShapeId:" .. tostring(otherShapeId));
	self:writeToLog(true, "onEnter:" .. tostring(onEnter) .. " onLeave:" .. tostring(onLeave) .. " onStay:" .. tostring(onStay));
	
	local vehicle = g_currentMission:getNodeObject(otherActorId);
	if vehicle ~= nil then
		local vehicleRootNode = vehicle.rootVehicle.rootNode;
		self:writeToLog(true, "vehicle found:" .. tostring(vehicleRootNode));
		if onEnter then
			local foundInTable = false;
			if spec.vehicleInTrigger[vehicleRootNode] ~= nil then
				foundInTable = true;
				spec.vehicleInTrigger[vehicleRootNode] = spec.vehicleInTrigger[vehicleRootNode] + 1;
			end
			
			if not foundInTable then
				spec.vehicleInTrigger[vehicleRootNode] = 1;
				spec.numVehicleInTrigger = spec.numVehicleInTrigger + 1;
				if spec.timerId == nil then
					self:startRepairVehicles();
				end
			end
			self:writeToLog(true, "vehicle counter:" .. tostring(spec.vehicleInTrigger[vehicleRootNode]));
		end
		if onLeave then
			if spec.vehicleInTrigger[vehicleRootNode] ~= nil then
				spec.vehicleInTrigger[vehicleRootNode] = spec.vehicleInTrigger[vehicleRootNode] - 1;
				if spec.vehicleInTrigger[vehicleRootNode] == 0 then
					spec.vehicleInTrigger[vehicleRootNode] = nil;
					spec.numVehicleInTrigger = spec.numVehicleInTrigger - 1;
					self:writeToLog(true, "vehicle removed");
				else
					self:writeToLog(true, "vehicle counter:" .. tostring(spec.vehicleInTrigger[vehicleRootNode]));
				end
			end
		end
	else
		self:writeToLog(true, "Not a vehicle");
	end
end

function RepairCarSpecialization:startRepairVehicles()
	local spec = self.spec_repairCar;
	self:writeToLog(true, "startRepairVehicles called: " .. tostring(spec.numVehicleInTrigger));
	
	if spec.numVehicleInTrigger > 0 then

		local actionDone = false;
		for vehicle, vehicleCount in pairs(spec.vehicleInTrigger) do
			local vehicle = g_currentMission.nodeToObject[vehicle];
			
			if vehicle ~= nil and vehicle.getDamageAmount ~= nil then
				self:writeToLog(true, "vehicle: " .. tostring(vehicle));
				local currentDamage = vehicle:getDamageAmount();
				self:writeToLog(true, "currentDamage: " .. tostring(currentDamage));
				if currentDamage >= 0.0001 then
					-- what will be the price for the repair step
					local repairStep = math.min(currentDamage, spec.repairPerInterval);
					self:writeToLog(true, "repairStep: " .. tostring(repairStep));
					local repairCosts = Wearable.calculateRepairPrice(self:getPrice(), repairStep) * spec.repairCostFactor;
					self:writeToLog(true, "repairCosts: " .. tostring(repairCosts));
					
					if spec.fillUnitIndex ~= nil then
						-- repair with filltype
						self:writeToLog(true, "repair with filltype");
						
						local liter = repairCosts / spec.fillTypePricePerLiter;
						self:writeToLog(true, "needed liter: " .. tostring(liter));
						-- reparieren, wenn es genug ist und abziehen
						if self:getFillUnitFillLevel(spec.fillUnitIndex) >= liter then
							self:addFillUnitFillLevel(self:getOwnerFarmId(), spec.fillUnitIndex, -liter, spec.fillType, ToolType.UNDEFINED, nil);
							vehicle:addDamageAmount(repairStep * -1, true);
							actionDone = true;
						end
					elseif g_currentMission:getMoney() >= repairCosts then					
						-- repair with money
						self:writeToLog(true, "repair with money")
						g_currentMission:addMoney(-repairCosts, self:getOwnerFarmId(), MoneyType.VEHICLE_REPAIR, true, true);
						vehicle:addDamageAmount(repairStep * -1, true);
						actionDone = true;
					end
				end
			end
		end

		if not actionDone then
			-- ready, remove timer
			-- drin lassen und solange ausführen wie ein vehicle im trigger ist
			-- spec.timerId = nil;
		else
			-- not ready, use timer
			if spec.timerId ~= nil then
				return true;
			else
				-- set intervall length here in miliseconds
				spec.timerId = addTimer(spec.repairInterval, "startRepairVehicles", self);
			end		
		end
	else
		-- no vehicle, remove timer
		spec.timerId = nil;
	end
end