require "test_helper"

class CnBill::ConverterTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @cmb = @family.accounts.create!(name: "招商银行储蓄卡", balance: 0, currency: "CNY",
                                    accountable: Depository.new)
    @converter = CnBill::Converter.new(family: @family, cmb_account: @cmb, self_names: [ "测试用户" ])
  end

  test "routes wechat rows by payment method" do
    result = @converter.convert(wechat: [
      wx(direction: "收入", method: "", party: "车友"),
      wx(method: "零钱", party: "早餐店"),
      wx(method: "零钱通", party: "超市"),
      wx(method: "招商银行储蓄卡(0000)", party: "家人", amount: "200"),
      wx(method: "中信银行信用卡(1111)", party: "肯德基")
    ])

    assert_equal 3, result.wallet.size
    assert_equal 1, result.cmb.size
    assert_equal 1, result.cards.size
    assert_equal "-200.00", result.cmb.first[:amount] # inflows-positive CSV
    assert_includes result.cmb.first[:tags], CnBill::WALLET_CHANNEL_TAG
  end

  test "drops bank statement row matched by wechat card-paid detail" do
    result = @converter.convert(
      wechat: [ wx(method: "招商银行储蓄卡(0000)", party: "家人", amount: "200", date: "2026-10-07") ],
      cmb: [ bank(date: "2026-10-07", amount: "-200", summary: "快捷支付", party: "微信转账") ]
    )
    assert_equal 1, result.cmb.size
    assert_equal "家人", result.cmb.first[:name]
    assert_equal 1, result.matched.size
  end

  test "classifies salary from own name and tags large transfers" do
    result = @converter.convert(cmb: [
      bank(date: "2026-10-13", amount: "10416.80", summary: "汇入汇款", party: "测试用户"),
      bank(date: "2026-11-10", amount: "200000", summary: "行内转账转入", party: "张三"),
      bank(date: "2026-10-14", amount: "-5828.33", summary: "掌上生活还款", party: "测试用户")
    ])

    salary, repayment, large = result.cmb.sort_by { |r| r[:date] }
    assert_equal "工资", salary[:category]
    assert_equal "工资（工资卡转入）", salary[:name]
    assert_includes large[:tags], CnBill::LARGE_TRANSFER_TAG
    assert_equal "信用卡还款", repayment[:category]
  end

  test "alipay: earnings become income, company-paid and zero rows skipped, card rows held" do
    result = @converter.convert(alipay: [
      ali(product: "余额宝-2026.10.30-收益发放", direction: "不计收支", amount: "0.01"),
      ali(method: "因公付(测试)", direction: "不计收支"),
      ali(amount: "0", method: ""),
      ali(method: "招商银行信用卡(2222)"),
      ali(direction: "支出", category_raw: "餐饮美食")
    ])

    assert_equal 2, result.alipay.size
    interest = result.alipay.find { |r| r[:category] == "利息收益" }
    assert_equal "0.01", interest[:amount]
    assert_equal 2, result.skipped.size
    assert_equal 1, result.cards.size
    assert_equal "餐饮", result.alipay.find { |r| r[:amount].start_with?("-") }[:category]
  end

  test "wechat partial refund keeps both legs" do
    result = @converter.convert(wechat: [
      wx(method: "零钱", amount: "50", status: "已退款(¥34.09)", party: "充电站"),
      wx(direction: "收入", method: "零钱", amount: "34.09", type: "充电站-退款", status: "已退款¥34.09", party: "充电站")
    ])
    assert_equal 2, result.wallet.size
    assert_equal "退款", result.wallet.find { |r| r[:amount] == "34.09" }[:category]
  end

  test "bank row duplicating an already-imported wallet-channel entry is dropped" do
    tag = @family.tags.create!(name: CnBill::WALLET_CHANNEL_TAG)
    txn = Transaction.new
    @cmb.entries.create!(entryable: txn, date: Date.new(2026, 10, 7), amount: 200,
                         name: "家人", currency: "CNY")
    txn.tags << tag

    result = @converter.convert(cmb: [
      bank(date: "2026-10-07", amount: "-200", summary: "快捷支付", party: "微信转账")
    ])
    assert_empty result.cmb
  end

  test "wealth sweeps are categorized and tagged for exclusion" do
    result = @converter.convert(cmb: [
      bank(date: "2026-01-02", amount: "2571.88", summary: "朝朝宝转出", party: "待清算电子汇差"),
      bank(date: "2026-01-05", amount: "-1000", summary: "朝朝宝转入", party: "待清算电子汇差")
    ])
    assert_equal 2, result.cmb.size
    result.cmb.each do |r|
      assert_equal "理财申赎", r[:category]
      assert_includes r[:tags], CnBill::WEALTH_SWEEP_TAG
    end
    assert_empty result.sweep
  end

  test "wealth sweeps emit mirror legs when the fund account exists" do
    zzb = @family.accounts.create!(name: CnBill::SWEEP_ACCOUNT_NAME, balance: 0,
                                   currency: "CNY", accountable: Depository.new(subtype: "savings"))
    converter = CnBill::Converter.new(family: @family, cmb_account: @cmb, sweep_account: zzb)
    result = converter.convert(cmb: [
      bank(date: "2026-01-02", amount: "2571.88", summary: "朝朝宝转出", party: "待清算电子汇差"),
      bank(date: "2026-01-05", amount: "-1000", summary: "朝朝宝转入", party: "待清算电子汇差")
    ])
    assert_equal 2, result.sweep.size
    out_leg = result.sweep.find { |r| r[:date] == "2026-01-02" }
    in_leg = result.sweep.find { |r| r[:date] == "2026-01-05" }
    assert_equal "-2571.88", out_leg[:amount] # fund outflow mirrors bank inflow
    assert_equal "1000.00", in_leg[:amount]
    assert_equal "朝朝宝转出至活期", out_leg[:name]
    assert_equal "活期转入朝朝宝", in_leg[:name]
  end

  test "ccb rows classify salary, sweeps, repayments and interest" do
    result = @converter.convert(ccb: [
      ccb(summary: "代理付款", amount: "10761.56", counterparty: "3719855101562295100010/渠道代发过渡户"),
      ccb(summary: "跨行转出", amount: "-10761.57", counterparty: "6214855328267535/测试用户"),
      ccb(summary: "跨行转出", amount: "-21340", counterparty: "6217856000045024824/戴倩倩"),
      ccb(summary: "信用卡卡号还款", amount: "-17", counterparty: "6221682827462289/测试用户"),
      ccb(summary: "利息存入", amount: "0.06", counterparty: ""),
      ccb(summary: "个人养老金充值", amount: "-12000", counterparty: "6270202393950002244/测试用户")
    ])

    salary, self_transfer, external, repayment, interest, pension = result.ccb
    assert_equal "工资", salary[:category]
    assert_equal "工资（建行代发）", salary[:name]
    assert_equal "本人账户划转", self_transfer[:name]
    assert_not_includes self_transfer[:tags], CnBill::LARGE_TRANSFER_TAG
    assert_equal "戴倩倩", external[:name]
    assert_includes external[:tags], CnBill::LARGE_TRANSFER_TAG
    assert_equal "信用卡还款", repayment[:category]
    assert_equal "利息收益", interest[:category]
    assert_equal "养老金缴存", pension[:category]
    assert_includes pension[:tags], CnBill::LARGE_TRANSFER_TAG
  end

  private
    def ccb(summary:, amount:, counterparty:, date: "2026-01-12")
      { date: date, summary: summary, amount: BigDecimal(amount),
        balance: BigDecimal("1000"), memo: "", counterparty: counterparty }
    end

    def wx(overrides = {})
      { date: "2026-10-07", type: "转账", party: "对方", product: "", direction: "支出",
        amount: BigDecimal("10"), method: "零钱", status: "支付成功", txn_id: SecureRandom.hex(4), note: "" }.merge(overrides)
        .transform_values { |v| v.is_a?(String) && v.match?(/\A\d+(\.\d+)?\z/) ? v : v }
        .then { |h| h.merge(amount: BigDecimal(h[:amount].to_s)) }
    end

    def ali(overrides = {})
      { date: "2026-10-30", category_raw: "日用百货", party: "商店", product: "商品",
        direction: "支出", amount: BigDecimal("16.90"), method: "余额宝", status: "交易成功",
        txn_id: SecureRandom.hex(4), note: "" }.merge(overrides)
        .then { |h| h.merge(amount: BigDecimal(h[:amount].to_s)) }
    end

    def bank(date:, amount:, summary:, party:)
      { date: date, amount: BigDecimal(amount), balance: BigDecimal("1000"), summary: summary, party: party }
    end
end
