class CnBillImportsController < ApplicationController
  layout "imports"

  def new
    @accounts = accessible_accounts.where(accountable_type: "Depository").alphabetically
  end

  def create
    uploads = params.fetch(:cn_bill, {}).permit(*CnBill::CHANNELS.keys)
    account_ids = params.fetch(:cn_bill_accounts, {}).permit(*CnBill::CHANNELS.keys)

    if uploads.values.all?(&:blank?)
      redirect_to new_cn_bill_import_path, alert: t("cn_bill_imports.create.no_files")
      return
    end

    result = CnBill::Batch.new(family: Current.family, uploads: uploads, account_ids: account_ids).process

    if result.imports.empty?
      message = result.errors.presence&.join("；") || t("cn_bill_imports.create.no_rows")
      redirect_to new_cn_bill_import_path, alert: message
      return
    end

    notice = t("cn_bill_imports.create.success", count: result.imports.size,
               rows: result.imports.sum(&:rows_count))
    notice += " " + t("cn_bill_imports.create.cards_pending", count: result.cards.size) if result.cards.any?
    notice += " " + t("cn_bill_imports.create.skipped", count: result.skipped.size) if result.skipped.any?
    notice += " " + result.errors.join("；") if result.errors.any?

    if result.imports.size == 1
      redirect_to import_path(result.imports.first), notice: notice
    else
      redirect_to imports_path, notice: notice
    end
  end
end
