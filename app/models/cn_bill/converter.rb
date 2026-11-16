# Turns parsed bill rows into per-account Sure CSV rows.
#
# Routing rules (avoid double counting across channels):
# - WeChat/Alipay rows paid from 零钱/零钱通/余额/余额宝 belong to the wallet account.
# - Rows paid with the CMB debit card belong to the CMB account, keeping the
#   merchant name (richer than the bank's generic 快捷支付 label). The matching
#   bank statement row is dropped, in-batch or against already-imported entries.
# - Credit-card-paid rows are reported separately (card accounts not modeled yet).
# - Large external transfers are tagged so a rule can exclude them from reports.
class CnBill::Converter
  ALIPAY_CATEGORIES = {
    "餐饮美食" => "餐饮", "日用百货" => "购物:日用", "爱车养车" => "交通:停车养车",
    "交通出行" => "交通", "商业服务" => "商业服务", "教育培训" => "教育", "保险" => "保险",
    "医疗健康" => "医疗", "生活服务" => "生活服务", "宠物" => "宠物", "亲友代付" => "人情往来:代付"
  }.freeze

  Result = Struct.new(:wallet, :alipay, :cmb, :cards, :skipped, :matched, keyword_init: true)

  def initialize(family:, cmb_account: nil, self_names: [])
    @family = family
    @cmb_account = cmb_account
    @self_names = self_names.compact.uniq
  end

  def convert(wechat: [], alipay: [], cmb: [])
    wallet, wx_cmb, wx_cards, wx_skipped = convert_wechat(wechat)
    ali_rows, ali_cards, ali_skipped = convert_alipay(alipay)
    cmb_rows, matched = convert_cmb(cmb, wx_cmb)

    Result.new(wallet: wallet, alipay: ali_rows, cmb: cmb_rows,
               cards: wx_cards + ali_cards, skipped: wx_skipped + ali_skipped, matched: matched)
  end

  private
    def convert_wechat(rows)
      wallet, cmb_detail, cards, skipped = [], [], [], []
      rows.each do |r|
        signed = r[:direction] == "收入" ? r[:amount] : -r[:amount]
        name = r[:party].presence || r[:product].presence || r[:type]
        notes = [ r[:product], r[:note], ("单号#{r[:txn_id]}" if r[:txn_id].present?) ].compact_blank.join(" | ")
        category = wechat_category(r)
        method = r[:method]

        if r[:direction] == "收入"
          wallet << CnBill.row(date: r[:date], amount: signed, name: name, category: category, tags: "微信", notes: notes)
        elsif method.in?([ "零钱", "零钱通" ])
          wallet << CnBill.row(date: r[:date], amount: signed, name: name, category: category, tags: "微信", notes: notes)
        elsif method.include?("招商银行储蓄卡")
          cmb_detail << CnBill.row(date: r[:date], amount: signed, name: name, category: category,
                                   tags: "微信|#{CnBill::WALLET_CHANNEL_TAG}", notes: notes)
        elsif method.include?("信用卡")
          card = method.include?("招商银行") ? "招行信用卡" : "中信信用卡"
          cards << CnBill.row(date: r[:date], amount: signed, name: name, category: category, tags: "微信|#{card}", notes: notes)
        else
          skipped << { channel: :wechat, date: r[:date], name: name, amount: r[:amount], reason: "未知支付方式 #{method}" }
        end
      end
      [ wallet, cmb_detail, cards, skipped ]
    end

    def wechat_category(r)
      return "退款" if r[:type].include?("退款") || (r[:status].include?("已退款") && r[:direction] == "收入")
      return "人情往来:红包" if r[:type].include?("红包")
      return "人情往来:转账" if r[:type] == "转账"
      return "其他收入" if r[:type] == "其他"
      "日常消费:其他"
    end

    def convert_alipay(rows)
      out, cards, skipped = [], [], []
      rows.each do |r|
        name = r[:party].presence || r[:product].to_s.truncate(40).presence || r[:category_raw]
        notes = [ r[:product], r[:note], ("单号#{r[:txn_id]}" if r[:txn_id].present?) ].compact_blank.join(" | ")
        category = ALIPAY_CATEGORIES[r[:category_raw]] || r[:category_raw]
        skip = lambda do |reason|
          skipped << { channel: :alipay, date: r[:date], name: name, amount: r[:amount], reason: reason }
        end

        if r[:amount].zero?
          skip.call("零金额（医保统筹等）")
        elsif r[:status] == "交易关闭"
          skip.call("交易关闭（未实际支付）")
        elsif r[:status] == "退款成功" || r[:category_raw] == "退款"
          skip.call("退款（与原支出抵消）")
        elsif r[:method].start_with?("因公付")
          skip.call("因公付（公司承担）")
        elsif r[:method].include?("信用卡")
          signed = r[:direction] == "支出" ? -r[:amount] : r[:amount]
          cards << CnBill.row(date: r[:date], amount: signed, name: name, category: category, tags: "支付宝|招行信用卡", notes: notes)
        elsif r[:product].include?("收益发放")
          out << CnBill.row(date: r[:date], amount: r[:amount], name: "余额宝收益", category: "利息收益", tags: "支付宝", notes: notes)
        elsif r[:direction] == "支出"
          out << CnBill.row(date: r[:date], amount: -r[:amount], name: name, category: category, tags: "支付宝", notes: notes)
        elsif r[:direction] == "收入"
          out << CnBill.row(date: r[:date], amount: r[:amount], name: name, category: category, tags: "支付宝", notes: notes)
        else
          skip.call("不计收支且未识别: #{r[:category_raw]}/#{r[:method]}")
        end
      end
      [ out, cards, skipped ]
    end

    def convert_cmb(bank_rows, wx_cmb_detail)
      remaining = bank_rows.dup
      matched = []
      detail_rows = []

      wx_cmb_detail.each do |wr|
        hit = remaining.find do |br|
          br[:amount] == BigDecimal(wr[:amount]) &&
            (Date.parse(br[:date]) - Date.parse(wr[:date])).abs <= 1 &&
            (br[:party].include?("微信") || br[:summary].include?("快捷"))
        end
        if hit
          remaining.delete(hit)
          matched << { wechat: wr, bank: hit }
          detail_rows << wr
        elsif existing_bank_entry_for(wr)
          matched << { wechat: wr, bank: nil } # already imported from a statement
        else
          detail_rows << wr
        end
      end

      bank_out = remaining.filter_map do |br|
        next if existing_wallet_channel_entry_for(br)
        cmb_row(br)
      end
      [ detail_rows + bank_out, matched ]
    end

    # A wallet-channel detail row may already sit in the CMB account as a
    # generic bank statement entry from an earlier import.
    def existing_bank_entry_for(wr)
      return false unless @cmb_account
      date = Date.parse(wr[:date])
      @cmb_account.entries.where(entryable_type: "Transaction",
                                 date: (date - 1)..(date + 1),
                                 amount: -BigDecimal(wr[:amount]))
                  .where("name ILIKE ? OR notes ILIKE ?", "%微信%", "%快捷%").exists?
    end

    # A bank statement row may duplicate a wallet-channel detail imported earlier.
    def existing_wallet_channel_entry_for(br)
      return false unless @cmb_account
      tag = @family.tags.find_by(name: CnBill::WALLET_CHANNEL_TAG)
      return false unless tag
      date = Date.parse(br[:date])
      @cmb_account.entries.where(entryable_type: "Transaction",
                                 date: (date - 1)..(date + 1),
                                 amount: -br[:amount])
                  .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                  .joins("INNER JOIN taggings ON taggings.taggable_id = transactions.id AND taggings.taggable_type = 'Transaction'")
                  .where(taggings: { tag_id: tag.id }).exists?
    end

    def cmb_row(br)
      summary, party = br[:summary], br[:party]
      tags, category = "招行", "其他"
      name = party.presence || summary

      if summary.include?("还款") || party.include?("还款")
        category = "信用卡还款"
      elsif summary.match?(/朝朝宝|理财|基金/)
        # Sweeps between checking and CMB's money-market fund are not
        # income/spending; tag them so a rule excludes them from reports.
        category = "理财申赎"
        tags += "|#{CnBill::WEALTH_SWEEP_TAG}"
      elsif summary.include?("汇入汇款") && party.in?(@self_names)
        category, name = "工资", "工资（工资卡转入）"
      elsif party.include?("拼多多")
        category = "购物"
      elsif summary.include?("转账") || summary.include?("转入")
        category = CnBill::SELF_TRANSFER_CATEGORY
        tags += "|#{CnBill::LARGE_TRANSFER_TAG}" if br[:amount].abs >= CnBill::LARGE_TRANSFER_THRESHOLD
      elsif summary.include?("快捷支付") || summary.include?("无卡")
        category = "购物"
      end

      notes = "#{summary} | 对手: #{party} | 联机余额 #{br[:balance]}"
      CnBill.row(date: br[:date], amount: br[:amount], name: name, category: category, tags: tags, notes: notes)
    end
end
