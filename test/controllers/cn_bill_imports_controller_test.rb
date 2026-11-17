require "test_helper"

class CnBillImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    ensure_tailwind_build
  end

  test "gets new" do
    get new_cn_bill_import_url
    assert_response :success
  end

  test "creates configured import from alipay upload" do
    assert_difference -> { @user.family.imports.count }, 1 do
      post cn_bill_imports_url, params: {
        cn_bill: { alipay: fixture_file_upload("cn_bills/alipay.csv", "text/csv") }
      }
    end

    import = @user.family.imports.ordered.first
    assert_redirected_to import_path(import)
    assert_equal "TransactionImport", import.type
    assert_equal 2, import.rows_count # company-paid row skipped
    assert_equal "inflows_positive", import.signage_convention
    assert_equal "%Y-%m-%d", import.date_format
    assert import.publishable?
    assert_equal "支付宝", import.account.name
  end

  test "creates configured import from ccb xls upload" do
    assert_difference -> { @user.family.imports.count }, 1 do
      post cn_bill_imports_url, params: {
        cn_bill: { ccb: fixture_file_upload("cn_bills/ccb.xls", "application/vnd.ms-excel") }
      }
    end

    import = @user.family.imports.ordered.first
    assert_redirected_to import_path(import)
    assert_equal 4, import.rows_count
    assert_equal "建设银行工资卡", import.account.name
    assert import.publishable?
  end

  test "rejects empty submission" do
    assert_no_difference -> { @user.family.imports.count } do
      post cn_bill_imports_url, params: { cn_bill: {} }
    end
    assert_redirected_to new_cn_bill_import_path
  end

  test "reports parse errors without creating imports" do
    assert_no_difference -> { @user.family.imports.count } do
      post cn_bill_imports_url, params: {
        cn_bill: { alipay: fixture_file_upload("test.txt", "text/csv") }
      }
    end
    assert_redirected_to new_cn_bill_import_path
    assert flash[:alert].present?
  end
end
