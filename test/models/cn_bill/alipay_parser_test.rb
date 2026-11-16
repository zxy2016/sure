require "test_helper"

class CnBill::AlipayParserTest < ActiveSupport::TestCase
  test "parses GB18030 export, skipping metadata lines" do
    content = file_fixture("cn_bills/alipay.csv").read
    rows = CnBill::AlipayParser.parse(content)

    assert_equal 3, rows.size
    first = rows.first
    assert_equal "2026-10-31", first[:date]
    assert_equal "测试超市", first[:party]
    assert_equal BigDecimal("7.91"), first[:amount]
    assert_equal "支出", first[:direction]
    assert_equal "余额宝", first[:method]
    assert_equal "TXN001", first[:txn_id]
  end

  test "parses UTF-8 content too" do
    content = file_fixture("cn_bills/alipay.csv").read.force_encoding(Encoding::GB18030).encode(Encoding::UTF_8)
    assert_equal 3, CnBill::AlipayParser.parse(content).size
  end

  test "raises when header is missing" do
    assert_raises(CnBill::Error) { CnBill::AlipayParser.parse("no header here") }
  end

  test "deduplicates rows by transaction id across overlapping exports" do
    content = file_fixture("cn_bills/alipay.csv").read.force_encoding(Encoding::GB18030).encode(Encoding::UTF_8)
    doubled = content + "\n" + content.lines.drop_while { |l| !l.start_with?("交易时间,") }.join
    assert_equal 3, CnBill::AlipayParser.parse(doubled).size
  end
end
