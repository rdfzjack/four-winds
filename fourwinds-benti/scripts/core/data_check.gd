extends RefCounted
## 检查数据文件之间是否对得上：角色、AI 参数、台词、机会卡。
## 只处理数据，不依赖画面节点。每个函数返回错误列表，空列表表示没问题。

## 机会卡效果 op -> 必须带的参数
const CARD_OP_PARAMS := {
	"money": ["amount"],
	"money_from_each": ["amount"],
	"money_to_each": ["amount"],
	"jail": ["days"],
	"goto": ["tile_type"],
	"state": ["state", "days"],
	"lose_most_expensive_property": [],
	"lose_mortgaged_properties": [],
	"demolish_one_house": [],
	"property_value_pct": ["target", "pct"],
	"upgrade_all_houses": [],
	"lose_deposit": [],
	"void_next_income": [],
	"bank_seize_payment": [],
}

const CARD_STATES := [
	"thief", "arsonist", "robber", "free_rent", "double_rent", "half_rent", "charity",
]

## AI 的 12 个原版参数
const AI_PARAMS := [
	"buyLandExpect",
	"buyCompanyExpect",
	"keepCashExpect",
	"keepCashDiff",
	"buildHouseExpect",
	"mortgageExpect",
	"unmortgageExpect",
	"removeExpect",
	"intendToAddMuchMoney",
	"acceptableDiffenceInTrade",
	"tradeCycle",
	"maxInvestment",
]


static func check_characters(characters: Array, ai: Dictionary, lines: Dictionary) -> Array:
	var errors: Array = []
	var profiles: Dictionary = ai.get("profiles", {})
	var line_sets: Dictionary = lines.get("characters", {})
	var conditions: Dictionary = lines.get("conditions", {})
	var seen := {}
	for c in characters:
		var cid := str(c.get("id", ""))
		var label := "角色 %s" % str(c.get("nickname", cid))
		if cid == "" or seen.has(cid):
			errors.append("%s 的 id 为空或重复" % label)
		seen[cid] = true
		var pid := str(c.get("ai_profile", ""))
		if not profiles.has(pid):
			errors.append("%s 的 AI 参数 \"%s\" 在 ai/profiles.json 里找不到" % [label, pid])
		else:
			for p in AI_PARAMS:
				if not profiles[pid].has(p):
					errors.append("%s 的 AI 参数缺少 %s" % [label, p])
		var lid := str(c.get("lines", ""))
		if not line_sets.has(lid):
			errors.append("%s 的台词 \"%s\" 在 lines/speech.json 里找不到" % [label, lid])
		else:
			for cond in conditions:
				var options: Variant = line_sets[lid].get(cond, [])
				if not (options is Array) or options.is_empty():
					errors.append("%s 缺少事件 %s 的台词" % [label, cond])
	return errors


static func check_cards(cards_file: Dictionary) -> Array:
	var errors: Array = []
	var cards: Array = cards_file.get("cards", [])
	if cards.is_empty():
		errors.append("没有机会卡")
	var seen := {}
	for card in cards:
		var cid := int(card.get("id", -1))
		var label := "机会卡 %d" % cid
		if seen.has(cid):
			errors.append("%s 的 id 重复" % label)
		seen[cid] = true
		if str(card.get("text", "")) == "":
			errors.append("%s 没有文字" % label)
		var effects: Array = card.get("effects", [])
		if effects.is_empty():
			errors.append("%s 没有效果" % label)
		for e in effects:
			var op := str(e.get("op", ""))
			if not CARD_OP_PARAMS.has(op):
				errors.append("%s 的效果 \"%s\" 不认识" % [label, op])
				continue
			for p in CARD_OP_PARAMS[op]:
				if not e.has(p):
					errors.append("%s 的效果 %s 缺少参数 %s" % [label, op, p])
			if op == "state" and not CARD_STATES.has(str(e.get("state", ""))):
				errors.append("%s 的状态 \"%s\" 不认识" % [label, str(e.get("state", ""))])
	return errors
