#define SUPPLY_OPEN_TIME (1 SECOND) //Time it takes to open supply door in seconds.
#define SUPPLY_CLOSE_TIME (15 SECONDS) //Time it takes to close supply door in seconds.
/// The full explosion-power-to-credits conversion formula. Also used in smallprogs.dm
#define PRESSURE_CRYSTAL_VALUATION(power) power ** 1.1 * 100
/// The number of peak points on the pressure crystal graph offering bonus credits
#define PRESSURE_CRYSTAL_PEAK_COUNT 3

//Codes for requisition post-transaction returns handling
///Requisition was not used, conduct a standard QM sale
#define RET_IGNORE 0
///Requisition was used, but no contract was fulfilled; return crate and do not process income.
#define RET_INSUFFICIENT 1
///Requisition was used successfully, and items are to be returned (either item rewards or excess goods shipped)
#define RET_SALE_SENDBACK 2
///Requisition was used successfully, and no items are to be returned (either no spare items, or a third party sale without item rewards)
#define RET_NOSENDBACK 3
///Requisition sheet was used and cargo was sent to third party requisitioner, but contract was not satisfied; no returns, no payment
#define RET_VOID 4

/datum/shipping_market

	var/list/commodities = list()
	var/time_between_shifts = 0
	var/time_until_shift = 0
	var/elapsed_shifts = 0
	var/demand_multiplier = 2
	var/list/active_traders = list()
	var/max_buy_items_at_once = 99
	var/last_market_update = 0
	var/mail_delivery_payout = 0

	var/list/datum/req_contract/req_contracts = list() // Requisition contracts for export, listed in clearinghouse
	var/max_req_contracts = 6 // Maximum contracts active in clearinghouse at one time (refills to this at each cycle)
	var/civ_contracts_active = 0 // To ensure at least one contract of each type is available
	var/aid_contracts_active = 0 // after market shift, these keep track of that
	var/sci_contracts_active = 0

	var/list/datum/req_contract/special_orders = list() // Special orders: contract manually sent by interested party, do not count towards limit

	var/list/supply_requests = list() // Pending requests, of type /datum/supply_order
	var/list/supply_history = list() // History of all approved requests, of type string

	// Both of these are string indexed because byond will whine and complain and explode otherwise
	/// Previously sold pressure crystal values, will negatively affect future sales (associative list of pressure to credit value)
	var/list/pressure_crystal_sales = list()
	/// Pressure crystal market peaks, will positively affect future sales (associative list of pressure to multipliers)
	var/list/pressure_crystal_peaks = list()

	var/points_per_crate = 10

	var/list/datum/req_contract/complete_orders = list()
 	/// amount of artifacts in next resupply crate
	var/artifact_resupply_amount = 0
	/// an artifact crate is already "on the way"
	var/artifacts_on_the_way = FALSE
	var/static/launch_distance = 0

	///List of pending crates (used only for transception antenna, nadir cargo system)
	var/list/pending_crates = list()

	New()
		..()

		add_commodity(new /datum/commodity/goldbar(src))

		for (var/commodity_path in (concrete_typesof(/datum/commodity) - /datum/commodity/goldbar))
			var/datum/commodity/C = new commodity_path(src)
			if(C.onmarket)
				add_commodity(C)
			else
				qdel(C)


		var/list/unique_traders = list(/datum/trader/gragg,/datum/trader/josh,/datum/trader/pianzi_hundan,
		/datum/trader/vurdalak,/datum/trader/buford)

		var/total_unique_traders = 5
		while(total_unique_traders > 0)
			total_unique_traders--
			var/the_trader = pick(unique_traders)
			src.active_traders += new the_trader(src)
			unique_traders -= the_trader

		src.active_traders += new /datum/trader/generic(src)
		src.active_traders += new /datum/trader/generic(src)

		while(length(src.req_contracts) < src.max_req_contracts)
			src.add_req_contract()

		update_shipping_data()

		//set up pressure crystal market peaks
		for (var/i in 1 to PRESSURE_CRYSTAL_PEAK_COUNT)
			var/value = rand(1, 230)
			src.pressure_crystal_peaks["[value]"] = (rand() * 2) + 1 //random number between 2 and 3

	proc/init()
		var/turf/spawnpoint
		for(var/turf/T in get_area_turfs(/area/supply/spawn_point))
			spawnpoint = T
			break

		var/turf/target
		for(var/turf/T in landmarks[LANDMARK_SUPPLY_DELIVERY])
			target = T
			break

		src.launch_distance = get_dist(spawnpoint, target)

	proc/add_commodity(var/datum/commodity/new_c)
		src.commodities["[new_c.comtype]"] = new_c

	proc/add_req_contract()
		if(length(req_contracts) >= max_req_contracts)
			return
		var/contract2make //picking path from which to generate the newly-added contract
		if(src.civ_contracts_active == 0) //guarantee presence of a civilian and scientific contract, for variety
			contract2make = pick_req_contract(/datum/req_contract/civilian)
		else if(src.sci_contracts_active == 0)
			contract2make = pick_req_contract(/datum/req_contract/scientific)
		else //do random gen, slightly higher weighting to aid, or civilian if we already have aid
			if(src.aid_contracts_active > 0)
				if(prob(55))
					contract2make = pick_req_contract(/datum/req_contract/civilian)
				else
					contract2make = pick_req_contract(/datum/req_contract/scientific)
			else
				switch(rand(1,10))
					if(1 to 3) contract2make = pick_req_contract(/datum/req_contract/civilian)
					if(4 to 7) contract2make = pick_req_contract(/datum/req_contract/aid)
					if(8 to 10) contract2make = pick_req_contract(/datum/req_contract/scientific)
		var/datum/req_contract/contractmade = new contract2make
		switch(contractmade.req_class)
			if(CIV_CONTRACT) src.civ_contracts_active++
			if(AID_CONTRACT) src.aid_contracts_active++
			if(SCI_CONTRACT) src.sci_contracts_active++
		src.req_contracts += contractmade

	proc/pick_req_contract(var/contract_path)
		var/order_weights = list()
		for(var/type in concrete_typesof(contract_path))
			var/datum/req_contract/O = type
			order_weights[type] = initial(O.weight)
		var/picked_contract = weighted_pick(order_weights)
		return picked_contract

	proc/timeleft()
		return max(0, src.time_until_shift - TIME)

	/// Returns the time in MM:SS format
	proc/get_market_timeleft()
		var/timeleft = src.timeleft() / 10
		if(timeleft)
			return "[add_zero(num2text((timeleft / 60) % 60),2)]:[add_zero(num2text(timeleft % 60), 2)]"

	proc/market_shift()
		src.last_market_update = TIME
		src.elapsed_shifts += 1

		// Chance of a commodity being hot. Sometimes the market is on fire.
		// Sometimes it is not. They still have to have a positive value roll,
		// so on average the % chance is actually about ~half this value.
		var/hot_chance = rand(10, 33)

		var/list/adjusted = list()

		for (var/type in src.commodities)
			var/datum/commodity/C = src.commodities[type]

			// First, get the basic RNG roll. Why -90 to 90? Well, because...
			var/modifier_roll = rand(-900, 900) / 10
			// ...we feed it into cos(x). -90 ... 0 ... 90 = 0 ... 1 ... 0
			// Then we subtract it from 1, so that roll=0 -> 0, roll=90 = 1
			var/price_mod = 1 - cos(modifier_roll)

			// All prices are initially based off of the base price.
			// Previously it was based off of the PREVIOUS price, which
			// could end up making certain commodies skyrocket to absurd
			// levels, or outright crash to literally worthless.
			// The price is then adjusted by either upperfluc or lowerfluc,
			// based on the roll and modifier above.
			var/price_adjust = C.baseprice
			if (modifier_roll >= 0)
				// Good rolls adjust based on the upper fluctuation...
				price_adjust += C.upperfluc * price_mod
			else
				// ... and bad rolls adjust on the lower one.
				price_adjust += C.lowerfluc * price_mod

			// At this point, the price is (hopefully) roughly on this
			// unfortunately upside-down scale of probabilities:
			//   |                                 | | v rare
			//    -                               -  |
			//     -_                           _-   | rare
			//       --___                 ___--     |
			//            ----____|____----          | common
			// lowerfluc      baseprice        upperfluc

			// This means that the price will always be between
			// (baseprice - abs(lowerfluc)) and (baseprice + upperfluc),
			// tending to land closer to the middle of the range.

			// If we had a good roll (> 0), roll a chance to make this
			// item Hot™! Hot items get a bigger bonus to their current value,
			// which is just pure random inflation.
			var/in_demand_modifier = 1
			if (modifier_roll > 0 && prob(hot_chance))
				// shit is on FIYAH! SELL SELL SELL!!
				// Hot prices are marked up by +50% to +200%.
				// This might be a bit much, but compensating for some of the
				// commodities that achieved stupidly inflated prices in the
				// old system. Can be adjusted down later if need be.
				in_demand_modifier = rand(150, 300) / 100

			// If (somehow) a price manages to become negative, make it
			// zero again so you aren't charged for disposing of it.
			// (comedy option: actual trash should cost money to dispose of.)
			// (please only do this when something that can recycle
			//  the crusher's scraps exist.)
			// We also strip off any weird decimals because it is 2053
			// and the penny has been abolished, along with all other coins.

			if(!adjusted[C])
				if(in_demand_modifier > 1)
					C.indemand = 1
				else
					C.indemand = 0
				C.price = max(round(price_adjust*in_demand_modifier), 0)
				adjusted += C
				adjusted[C] = 1

			if(C.linked_commodities)
				for(var/linked in C.linked_commodities)
					for(var/comtype in src.commodities)
						var/datum/commodity/commodity = src.commodities[comtype]
						if(!adjusted[commodity])
							if(linked == commodity.type)
								commodity.price = C.price * C.linked_commodities[linked]
								commodity.indemand = C.indemand
								adjusted += commodity
								adjusted[commodity] = 1

		// Shuffle trader visibility around a bit
		for (var/datum/trader/T in src.active_traders)
			if (T.hidden)
				if (prob(T.chance_arrive))
					T.hidden = 0
					T.current_message = pick(T.dialogue_greet)
					T.patience = rand(T.base_patience[1],T.base_patience[2])
					T.set_up_goods(FALSE)
			else
				if (prob(T.chance_leave))
					T.hidden = 1

		// Remove / time out contracts by variant...
		for(var/datum/req_contract/RC in src.req_contracts)
			switch(RC.req_class)
				if(CIV_CONTRACT)
					if(!RC.pinned)
						src.civ_contracts_active--
						src.req_contracts -= RC
						qdel(RC)
				if(SCI_CONTRACT)
					if(!RC.pinned)
						src.sci_contracts_active--
						src.req_contracts -= RC
						qdel(RC)
				if(AID_CONTRACT)
					var/datum/req_contract/aid/RCAID = RC
					if(RCAID.cycles_remaining > 0)
						RCAID.cycles_remaining--
					else
						src.aid_contracts_active--
						src.req_contracts -= RC
						qdel(RC)

		//... and repopulate afterwards.
		while(length(src.req_contracts) < src.max_req_contracts)
			src.add_req_contract()

		#ifndef FUCK_OFF_WITH_THE_MAIL
		if (src.elapsed_shifts % 2 == 0) //every other shift
			SPAWN(0)
				src.generate_mail()
		#endif

		SPAWN(5 SECONDS)
			// 20% chance to shuffle out generic traders for a new one
			// Do this after a short delay so QMs can finish any last-second deals
			var/removed_count = 0
			for (var/datum/trader/generic/GT in src.active_traders)
				if (prob(20))
					src.active_traders -= GT
					removed_count++

			while(removed_count > 0)
				removed_count--
				src.active_traders += new /datum/trader/generic(src)

			update_shipping_data()
			update_buy_prices()

	proc/generate_mail()
		var/alive_players = 0
		var/target_percentage = 0.375
		for(var/datum/job/civilian/mail_courier/J in job_controls.staple_jobs)
			if (J.assigned)
				target_percentage = 0.5
		for(var/client/C)
			if (!isliving(C.mob) || isdead(C.mob) || !ishuman(C.mob) || inafterlife(C.mob))
				continue
			alive_players++

		// the intent here is 3 pieces of mail, per player, per hour
		// average market shift is 7.5 min
		// one hour / 7.5 minutes = 8
		// so, 3 / 8 = 37.5% of players should get mail
		// hi it's me after sleeping in a bit -- lowering it down a little (37.5 -> 25)
		// readjusting upwards slightly as the mail delivery rate was cut
		var/mail_amount = ceil(alive_players * target_percentage)
		logTheThing(LOG_STATION, null, "Mail: [alive_players] player\s, generating [mail_amount] pieces of mail.")
		mail_amount = min(mail_amount, 100) // no more infinite ~~nuggets~~ mail, please
		if (alive_players >= 1)
			var/obj/storage/crate/mail/mail_crate = new
			mail_crate.name = "mail box"
			mail_crate.desc = "Hopefully this mail gets delivered, or people might go postal."
			var/list/created_mail = create_random_mail(mail_crate, how_many = mail_amount)
			if (length(created_mail) == 0)
				logTheThing(LOG_STATION, null, "Mail: No mail created, welp")
				qdel(mail_crate)
			else
				if (length(created_mail) > 5)
					// add a free mail satchel if there's a particularly large amount of mail
					// it's a produce satchel but it just holds mail.
					var/obj/item/satchel/mail/mailbag = new(mail_crate)
					mailbag.set_loc(mail_crate)

				if (src.mail_delivery_payout > 0)
					var/obj/item/currency/spacecash/payout = new /obj/item/currency/spacecash(mail_crate, src.mail_delivery_payout)
					payout.set_loc(mail_crate)

				logTheThing(LOG_STATION, null, "Mail: Created [created_mail.len] packages, shipping now.")
				shippingmarket.receive_crate(mail_crate)

	/// update the buy price of items based on market fluctuations
	/// remove in demand goods from traders; they're all out!
	proc/update_buy_prices()
		var/new_cost = 0
		var/multiplier = 1
		for (var/datum/supply_packs/pack in qm_supply_cache)
			new_cost = 0
			for(var/type in pack.contains)
				if(pack.contains[type] && pack.contains[type] > 1)
					multiplier = pack.contains[type]
				else
					multiplier = 1
				if(pack.amount && pack.amount > 1)
					multiplier *= pack.amount
				for (var/ctype in src.commodities)
					var/datum/commodity/C = src.commodities[ctype]
					if(ispath(type,C.comtype))
						if(C.indemand)
							multiplier *= src.demand_multiplier
						new_cost += C.price * multiplier

			new_cost += src.points_per_crate

			if(pack.cost < new_cost)
				pack.cost = new_cost
			if(pack.cost > new_cost && pack.cost > pack.basecost)
				pack.cost = max(new_cost,pack.basecost)

			if(pack.exhaustion > 0)
				pack.exhaustion = round(pack.exhaustion*0.5)

		for (var/ctype in src.commodities)
			var/datum/commodity/C1 = src.commodities[ctype]
			for(var/datum/trader/T in src.active_traders)
				for(var/datum/commodity/C2 in T.goods_sell)
					if(C1.comtype == C2.comtype)
						if(C1.indemand)
							C2.amount = 0






	proc/calculate_artifact_price(var/modifier, var/correctness)
		return ((modifier**1.5) * PAY_EMBEZZLED * correctness)

	proc/sell_artifact(obj/sell_art, var/datum/artifact/sell_art_datum)
		var/price = 0
		var/modifier = sell_art_datum.get_rarity_modifier()
		var/obj/item/sticker/postit/artifact_paper/pap = locate(/obj/item/sticker/postit/artifact_paper/) in sell_art.vis_contents
		var/obj/item/card/id/scan = sell_art_datum.scan
		var/datum/db_record/account = sell_art_datum.account

		// calculate price
		price = calculate_artifact_price(modifier, max(pap?.lastAnalysis, 1))
		price *= randfloat(0.9, 1.3)
		price = round(price, 4)

		// track score
		if(pap)
			score_tracker.artifacts_analyzed++
		if(pap?.lastAnalysis >= 3)
			score_tracker.artifacts_correctly_analyzed++

		// add to artifact resupply amount
		src.artifact_resupply_amount += modifier*0.8*pap?.lastAnalysis*randfloat(1,1.2) // t1 artifact: 0.25 artifacts, t4 artifact: 1.53 artifacts
		// send artifact resupply
		if(src.artifact_resupply_amount > 1 && !src.artifacts_on_the_way)
			src.artifacts_on_the_way = TRUE
			SPAWN(1 MINUTES)
				// handle the artifact amount
				var/art_amount = round(artifact_resupply_amount)
				artifact_resupply_amount -= art_amount
				// message
				var/datum/signal/pdaSignal = get_free_signal()
				pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT",  "group"=list(MGD_CARGO, MGD_SCIENCE), "sender"="00000000", "message"="Notification: Incoming artifact resupply crate. ([art_amount] objects)")
				radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)
				// make crate
				var/obj/storage/crate/artcrate = new /obj/storage/crate()
				artcrate.name = "Artifact Resupply Crate"
				// populate with artifacts
				for(var/i = 1 to art_amount)
					new /obj/artifact_type_spawner/vurdalak(artcrate)
				// ship out!
				shippingmarket.receive_crate(artcrate)
				src.artifacts_on_the_way = FALSE

		// sell
		if (scan && account)
			wagesystem.shipping_budget += price / 2
			account["current_money"] += price / 2
		else
			wagesystem.shipping_budget += price
		qdel(sell_art)

		// give PDA group messages
		var/datum/signal/pdaSignal = get_free_signal()
		var/message = "Notification: [price] credits earned from outgoing artifact \'[sell_art.name]\'. "
		if(pap)
			if (pap.lastAnalysis == 3)
				message += "Analysis was correct."
			else
				message += "Analysis was incorrect. Misidentified traits: [pap.lastAnalysisErrors]."
		else
			message += "Artifact was not analyzed."
		pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT",  "group"=list(MGD_CARGO, MGD_SCIENCE, MGA_SALES), "sender"="00000000", "message"=message)
		radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)

	// Returns value of whatever the list of objects would sell for
	proc/appraise_value(var/list/obj/items, var/list/commodities_list, var/sell = 1)

		// TODO: Does this handle common containers like satchels?
		// If not, maybe they should?
		// Maybe some way to send them through mail chutes without
		// dumping the contents out would be good

		var/duckets = 0  // fuck yeah duckets  ((noun) Cash, money or bills, from "ducats")
		var/add = 0
		if (!commodities_list)
			for(var/obj/O in items)
				for (var/C in src.commodities) // Key is type of the commodity
					var/datum/commodity/CM = commodities[C]
					if (istype(O, CM.comtype))
						add = CM.price
						if (CM.indemand)
							add *= shippingmarket.demand_multiplier
						if (istype(O, /obj/item/raw_material) || istype(O, /obj/item/sheet) || istype(O, /obj/item/material_piece) || istype(O, /obj/item/plant) || istype(O, /obj/item/reagent_containers/food/snacks/plant) || istype(O, /obj/item/reagent_containers/food/snacks/pizza)) //not many wanderers travel to these far reaches. welcome, honored guest.
							add *= O:amount // TODO: fix for snacks
							if (sell)
								qdel(O)
						else
							if (sell)
								qdel(O)
						duckets += add
						break
					else if (istype(O, /obj/item/currency/spacecash))
						duckets += 0.9 * O:amount
						if (sell)
							qdel(O)
						break
					else if (istype(O, /obj/item/pressure_crystal))
						duckets += src.appraise_pressure_crystal(O, sell)
						if (sell)
							qdel(O)
						break
					else if (O.artifact && sell)
						src.sell_artifact(O, O.artifact)
		else // Please excuse this duplicate code, I'm gonna change trader commodity lists into associative ones later I swear
			for(var/obj/O in items)
				for (var/datum/commodity/C in commodities_list)
					if (istype(O, C.comtype))
						add = C.price
						if (C.indemand)
							add *= shippingmarket.demand_multiplier
						if (istype(O, /obj/item/raw_material) || istype(O, /obj/item/sheet) || istype(O, /obj/item/material_piece) || istype(O, /obj/item/plant) || istype(O, /obj/item/reagent_containers/food/snacks/plant) || istype(O, /obj/item/reagent_containers/food/snacks/pizza)) //have you come to bring us from this desolate land?
							add *= O:amount // TODO: fix for snacks
							if (sell)
								qdel(O)
						else
							if (sell)
								qdel(O)
						duckets += add
						break
					else if (istype(O, /obj/item/currency/spacecash))
						duckets += O:amount
						if (sell)
							qdel(O)
						break

		return duckets

	proc/appraise_pressure_crystal(var/obj/item/pressure_crystal/pc, var/sell = 0)
		if (pc.pressure <= 0 || pc.broken)
			return
		//calculate the base value
		var/value = PRESSURE_CRYSTAL_VALUATION(pc.pressure)
		//for each previously sold pressure crystal
		for (var/sale in src.pressure_crystal_sales)
			var/sale_value = text2num(sale)
			//calculate a modifier based on the proximity of our current pressure to the previous one
			//scales by a simple x^2 curve, stretched by the magnitude of the sale pressure (ie bigger bombs affect larger ranges)
			//obligatory desmos: https://www.desmos.com/calculator/mumuykqlju
			var/modifier = 1/(sale_value * 3) * ((pc.pressure - sale_value) ** 2)
			if (modifier < 1) //a range cutoff to ensure we never add credit value
				value *= modifier
		for (var/peak in src.pressure_crystal_peaks)
			var/peak_value = text2num(peak) //I hate byond lists
			//very similar to above except inverted and bounded by the multiplier of the peak
			//another desmos: https://www.desmos.com/calculator/ahhoxuwho8
			var/modifier = -1/(peak_value * 3) * ((pc.pressure - peak_value) ** 2) + src.pressure_crystal_peaks[peak]
			if (modifier > 1)
				value *= modifier
		value = round(value)
		if (sell && value > 0)
			src.pressure_crystal_sales["[pc.pressure]"] = value
			var/datum/signal/pdaSignal = get_free_signal() // tell sciv
			var/message = "Notification: [value] credits earned from outgoing pressure crystal at [pc.pressure] kiloblast. "
			pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT",  "group"=list(MGD_SCIENCE), "sender"="00000000", "message"=message)
			radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)

		return value

	proc/handle_returns(obj/storage/crate/sold_crate,var/return_code)
		if(return_code == RET_INSUFFICIENT) //clarifies purpose for crate return
			sold_crate.name = "Returned Requisitions Crate"
		else
			sold_crate.name = "Reimbursed Requisitions Crate"
		SPAWN(rand(18,24) SECONDS)
			shippingmarket.receive_crate(sold_crate)

	proc/sell_crate(obj/storage/crate/sell_crate, var/list/commodities_list)
		var/obj/item/card/id/scan = sell_crate.scan
		var/datum/db_record/account = sell_crate.account
		var/duckets

		var/datum/req_contract/contract_to_clear //track picked contract for later cleanup

		var/return_handling = RET_IGNORE //used for crate return management after requisitions

		var/delivery_code = sell_crate.delivery_destination
		var/has_requisition_code = !!findtext(delivery_code,"REQ-")

		//requisition contract shipments receive different messages and handling
		if(has_requisition_code)
			return_handling = RET_INSUFFICIENT
			var/datum/req_contract/contract

			if(length(special_orders) && delivery_code == "REQ-THIRDPARTY")
				for(var/datum/req_contract/special/prospective in special_orders)
					if(locate(prospective.req_sheet) in sell_crate.contents)
						return_handling = RET_VOID // once a third party recipient is confirmed, sending your crate is irrevocable
						contract = prospective
						break

			else if(length(req_contracts))
				for(var/datum/req_contract/prospective in req_contracts)
					if(prospective.req_code == delivery_code)
						contract = prospective
						break

			if(contract)
				var/success = contract.requisify(sell_crate)
				if(success)
					return_handling = RET_SALE_SENDBACK
					contract_to_clear = contract
					switch(contract.req_class)
						if(CIV_CONTRACT) src.civ_contracts_active--
						if(AID_CONTRACT) src.aid_contracts_active--
						if(SCI_CONTRACT) src.sci_contracts_active--
					duckets += contract.payout
					contract.count += 1
					if(length(contract.item_rewarders))
						for(var/datum/rc_itemreward/giftback in contract.item_rewarders)
							var/reward = giftback.build_reward()
							if(reward) sell_crate.contents += reward
							else logTheThing(LOG_DEBUG, null, "QM contract [contract.type] failed to build [giftback.type]")
					else if(success == REQ_RETURN_FULLSALE)
						return_handling = RET_NOSENDBACK


		#ifdef SECRETS_ENABLED
		send_to_canada_post(sell_crate)
		#endif

		if(return_handling)
			if(return_handling >= RET_NOSENDBACK)
				qdel(sell_crate)
				if(return_handling == RET_VOID) return
			else
				handle_returns(sell_crate, return_handling)
				if(return_handling == RET_INSUFFICIENT)
					var/datum/signal/pdaSignal = get_free_signal()
					var/returnmsg = "Notification: No contract fulfilled by Requisition crate. Returning as sent."
					if(delivery_code == "REQ-THIRDPARTY") returnmsg = "Notification: Third-party delivery requires physical requisition sheet. Returning as sent."
					pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT",  "group"=list(MGD_CARGO, MGA_SALES), "sender"="00000000", "message"="[returnmsg]")
					pdaSignal.transmission_method = TRANSMISSION_RADIO
					radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)
					return
			if(req_contracts.Find(contract_to_clear))
				req_contracts -= contract_to_clear
				complete_orders += contract_to_clear
				qdel(contract_to_clear)
			else if(special_orders.Find(contract_to_clear))
				special_orders -= contract_to_clear
				complete_orders += contract_to_clear
				qdel(contract_to_clear)
		else
			duckets += src.appraise_value(sell_crate, commodities_list, 1) + src.points_per_crate
			qdel(sell_crate)

		var/salesource = "last outgoing shipment"
		if(return_handling >= RET_SALE_SENDBACK) //modify sale message if requisitions are source of income
			salesource = "requisition contract fulfillment"

		var/datum/signal/pdaSignal = get_free_signal()
		if(scan && account)
			var/share_NT = round(duckets / 2,1) // NT gets half the money, decimals rounded up in case of uneven sale price
			var/share_seller = duckets - share_NT // you get whatever remainds, sorry bud
			wagesystem.shipping_budget += share_NT
			account["current_money"] += share_seller
			logTheThing(LOG_STATION, null, "Cargo sale split [share_seller] credits to [scan.registered], whoever that is.")
			pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT",  "group"=list(MGD_CARGO, MGA_SALES), "sender"="00000000", "message"="Notification: [duckets] credits earned from [salesource]. Splitting half of profits with [scan.registered].")
		else
			wagesystem.shipping_budget += duckets
			pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT",  "group"=list(MGD_CARGO, MGA_SALES), "sender"="00000000", "message"="Notification: [duckets] credits earned from [salesource].")

		radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)

	//NADIR: Transception antenna cargo I/O
#ifdef MAP_OVERRIDE_NADIR
	proc/receive_crate(atom/movable/shipped_thing, force = FALSE)

		if(force)
			var/obj/machinery/transception_pad/toRecv = pick(by_type[/obj/machinery/transception_pad])
			var/turf/T = get_turf(toRecv) || get_turf(pick_landmark(LANDMARK_LATEJOIN)) //AAAAA
			shipped_thing.set_loc(T)
			if(get_turf(toRecv))
				showswirl(get_turf(toRecv))



		else
			pending_crates.Add(shipped_thing)

			var/datum/signal/pdaSignal = get_free_signal()
			pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT", "group"=list(MGD_CARGO, MGA_SHIPPING), "sender"="00000000", "message"="New shipment pending transport: [shipped_thing.name].")
			radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)

#else
	proc/receive_crate(atom/movable/shipped_thing, force = FALSE)

		var/turf/spawnpoint
		for(var/turf/T in get_area_turfs(/area/supply/spawn_point))
			spawnpoint = T
			break

		var/turf/target
		for(var/turf/T in landmarks[LANDMARK_SUPPLY_DELIVERY])
			target = T
			break

		if (!spawnpoint)
			if(force)
				shipped_thing.set_loc(get_turf(pick_landmark(LANDMARK_LATEJOIN)))
			logTheThing(LOG_DEBUG, null, "<b>Shipping: </b> No spawn turfs found! Can't deliver crate")
			return

		if (!target)
			if(force)
				shipped_thing.set_loc(get_turf(pick_landmark(LANDMARK_LATEJOIN)))
			logTheThing(LOG_DEBUG, null, "<b>Shipping: </b> No target turfs found! Can't deliver crate")
			return

		shipped_thing.set_loc(spawnpoint)

		var/datum/signal/pdaSignal = get_free_signal()
		pdaSignal.data = list("address_1"="00000000", "command"="text_message", "sender_name"="CARGO-MAILBOT", "group"=list(MGD_CARGO, MGA_SHIPPING), "sender"="00000000", "message"="Shipment arriving to Cargo Bay: [shipped_thing.name].")
		radio_controller.get_frequency(FREQ_PDA).post_packet_without_source(pdaSignal)

		for(var/obj/machinery/door/poddoor/P in by_type[/obj/machinery/door])
			if (P.id == "qm_dock")
				playsound(P.loc, 'sound/machines/bellalert.ogg', 50, 0)
				SPAWN(SUPPLY_OPEN_TIME)
					if (P?.density)
						P.open()
				SPAWN(SUPPLY_CLOSE_TIME)
					if (P && !P.density)
						P.close()

		shipped_thing.throw_at(target, src.launch_distance, 1)
#endif

	proc/get_path_to_market()
		var/list/bounds = list()
		for(var/turf/T in landmarks[LANDMARK_SUPPLY_DELIVERY])
			bounds += T
		bounds += get_area_turfs(/area/supply/sell_point)
		bounds += get_area_turfs(/area/supply/spawn_point)
		var/min_x = INFINITY
		var/max_x = 0
		var/min_y = INFINITY
		var/max_y = 0
		for(var/turf/boundry as anything in bounds)
			min_x = min(min_x, boundry.x)
			min_y = min(min_y, boundry.y)
			max_x = max(max_x, boundry.x)
			max_y = max(max_y, boundry.y)

		. = block(locate(min_x, min_y, Z_LEVEL_STATION), locate(max_x, max_y, Z_LEVEL_STATION))

	//needs to be called whenever active_traders or req_contracts changes
	proc/update_shipping_data()
		for_by_tcl(computer, /obj/machinery/computer/barcode)
			computer.update_static_data()
		for_by_tcl(barcoder, /obj/item/portable_barcoder)
			barcoder.update_destinations()

// Debugging and admin verbs (mostly coder)

/client/proc/cmd_modify_market_variables()
	SET_ADMIN_CAT(ADMIN_CAT_DEBUG)
	set name = "Edit Market Variables"
	ADMIN_ONLY
	SHOW_VERB_DESC
	if (shippingmarket == null) boutput(src, "UH OH!")
	else src.debug_variables(shippingmarket)

/client/proc/BK_finance_debug()
	SET_ADMIN_CAT(ADMIN_CAT_DEBUG)
	set name = "Financial Info"
	set desc = "Shows budget variables and current market prices."
	ADMIN_ONLY
	SHOW_VERB_DESC
	var/payroll = 0
	var/totalfunds = wagesystem.station_budget + wagesystem.research_budget + wagesystem.shipping_budget
	for(var/datum/db_record/R as anything in data_core.bank.records)
		payroll += R["wage"]

	var/dat = {"<B>Budget Variables:</B>
	<BR><BR><u><b>Total Station Funds:</b> [num2text(totalfunds,50)][CREDIT_SIGN]</u>
	<BR>
	<BR><b>Current Payroll Budget:</b> [num2text(wagesystem.station_budget,50)][CREDIT_SIGN]
	<BR><b>Current Research Budget:</b> [num2text(wagesystem.research_budget,50)][CREDIT_SIGN]
	<BR><b>Current Shipping Budget:</b> [num2text(wagesystem.shipping_budget,50)][CREDIT_SIGN]
	<BR>
	<b>Current Payroll Cost:</b> [payroll][CREDIT_SIGN]<HR>"}

	dat += "Shipping Market Prices<BR><BR>"
	for(var/item_type in shippingmarket.commodities)
		var/datum/commodity/C = shippingmarket.commodities[item_type]
		var/viewprice = C.price
		if (C.indemand) viewprice *= shippingmarket.demand_multiplier
		dat += "<BR><B>[C.comname]:</B> [viewprice][CREDIT_SIGN] per unit "
		if (C.indemand) dat += " <b>(High Demand!)</b>"
	var/timer = shippingmarket.get_market_timeleft()
	dat += "<BR><HR><b>Next Price Shift:</B> [timer]<BR>"
	dat += "Last updated: [shippingmarket.last_market_update]<BR>"

	dat += "<BR><BR><HR><b>Lottery</b><BR><BR>Current Jackpot = [wagesystem.lotteryJackpot] <BR>"
	dat += "Current Round = [wagesystem.lotteryRound] <BR>"

	dat += "List of rounds and their numbers:"
	for(var/j = 1, j < wagesystem.lotteryRound + 1, j++)
		dat += "<BR>Round [j]: "
		for(var/i = 1, i < 5, i++)
			dat += "[wagesystem.winningNumbers[i][j]] "

	usr.Browse(dat, "window=budgetdebug;size=400x400")

/client/proc/BK_alter_funds()
	SET_ADMIN_CAT(ADMIN_CAT_DEBUG)
	set name = "Alter Budget"
	set desc = "Add to or subtract from a budget."
	ADMIN_ONLY
	SHOW_VERB_DESC
	var/trans = input("Which budget?", "Budgeting", null, null) in list("Payroll", "Shipping", "Research")
	if (!trans) return

	var/amount = input(usr, "How much to add to this budget?", "Funds", 0) as null|num
	if (!isnum_safe(amount)) return

	switch(trans)
		if("Payroll")
			wagesystem.station_budget += amount
			if (wagesystem.station_budget < 0) wagesystem.station_budget = 0
		if("Shipping")
			wagesystem.shipping_budget += amount
			if (wagesystem.shipping_budget < 0) wagesystem.shipping_budget = 0
		if("Research")
			wagesystem.research_budget += amount
			if (wagesystem.research_budget < 0) wagesystem.research_budget = 0
		else
			boutput(usr, SPAN_ALERT("Whatever you did, it didn't work."))
			return

#undef SUPPLY_OPEN_TIME
#undef SUPPLY_CLOSE_TIME
