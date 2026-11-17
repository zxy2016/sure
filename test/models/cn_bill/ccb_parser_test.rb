require "test_helper"

class CnBill::CcbParserTest < ActiveSupport::TestCase
  test "parses BIFF xls export with signed amounts and running balance" do
    parser = CnBill::CcbParser.new
    rows = parser.parse(file_fixture("cn_bills/ccb.xls").read)

    assert_equal 4, rows.size
    first = rows.first
    assert_equal "2026-01-12", first[:date]
    assert_equal "代理付款", first[:summary]
    assert_equal BigDecimal("10761.56"), first[:amount]
    assert_equal BigDecimal("10761.57"), first[:balance]
    assert_equal BigDecimal("-10761.57"), rows[1][:amount]
    assert_equal [ "测试用户" ], parser.account_names
  end

  test "extracts party name from account/name counterparty field" do
    assert_equal "张小禹", CnBill::CcbParser.party_name("6214855328267535/张小禹")
    assert_equal "3719855101562295100010", CnBill::CcbParser.party_name("3719855101562295100010")
    assert_equal "", CnBill::CcbParser.party_name("")
  end

  test "deduplicates identical rows across overlapping exports" do
    content = file_fixture("cn_bills/ccb.xls").read
    parser = CnBill::CcbParser.new
    twice = parser.parse(content) + parser.parse(content)
    assert_equal 4, twice.uniq { |r| [ r[:date], r[:amount], r[:balance] ] }.size
  end

  test "raises on non-xls content" do
    assert_raises(CnBill::Error) { CnBill::CcbParser.parse("not a spreadsheet") }
  end
end
