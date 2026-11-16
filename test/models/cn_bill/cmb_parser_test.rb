require "test_helper"

class CnBill::CmbParserTest < ActiveSupport::TestCase
  OCTOBER = <<~TEXT
    招商银行交易流水
    2026-10-01 -- 2026-10-31
    户      名：测试用户                    账号：6214********0000
    记账日期      货币    交易金额        联机余额      交易摘要          对手信息
    2026-10-02     CNY        -40.79        2,812.89       快捷支付          测试商户
    2026-10-13     CNY        10,416.80     12,461.54      汇入汇款          测试用户
  TEXT

  NOVEMBER = <<~TEXT
    招商银行交易流水
    2026-11-01 -- 2026-11-14
    户      名：测试用户
    2026-11-10     CNY        200,000.00    212,461.54     行内转账转入       张三
  TEXT

  test "parses columnar statement lines" do
    rows = CnBill::CmbParser.new.parse_text(OCTOBER)
    assert_equal 2, rows.size
    assert_equal({ date: "2026-10-02", amount: BigDecimal("-40.79"),
                   balance: BigDecimal("2812.89"), summary: "快捷支付", party: "测试商户" }, rows.first)
    assert_equal BigDecimal("10416.80"), rows.last[:amount]
  end

  test "orders multiple statements by printed range, preserving intra-day order" do
    parser = CnBill::CmbParser.new
    rows = parser.parse_texts([ NOVEMBER, OCTOBER ])
    assert_equal %w[2026-10-02 2026-10-13 2026-11-10], rows.map { |r| r[:date] }
    assert_equal [ "测试用户" ], parser.account_names
  end

  test "deduplicates identical rows across overlapping statements" do
    parser = CnBill::CmbParser.new
    assert_equal 2, parser.parse_texts([ OCTOBER, OCTOBER ]).size
  end
end
