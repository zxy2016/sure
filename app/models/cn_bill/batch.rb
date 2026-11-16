# Orchestrates a front-end upload batch: parse the uploaded bill files, convert
# them, and create fully-configured TransactionImport records that the user
# reviews and publishes through the standard import UI.
#
# Also ensures a rule that excludes large external transfers from reports
# (they move the balance but are not income/spending).
class CnBill::Batch
  MAX_FILE_SIZE = 10.megabytes

  Result = Struct.new(:imports, :cards, :skipped, :matched, :errors, keyword_init: true)

  def initialize(family:, uploads:, account_ids: {})
    @family = family
    @uploads = uploads.to_h.symbolize_keys.slice(:wechat, :alipay, :cmb)
    @account_ids = account_ids.to_h.symbolize_keys
  end

  def process
    errors = []
    parsed = { wechat: [], alipay: [], cmb: [] }
    self_names = []

    @uploads.each do |channel, file|
      next if file.blank?
      if file.size > MAX_FILE_SIZE
        errors << "#{channel_label(channel)}: 文件超过 #{MAX_FILE_SIZE / 1.megabyte}MB"
        next
      end
      content = file.read
      case channel
      when :wechat then parsed[:wechat] = CnBill::WechatParser.parse(content)
      when :alipay then parsed[:alipay] = CnBill::AlipayParser.parse(content)
      when :cmb
        parser = CnBill::CmbParser.new
        parsed[:cmb] = parser.parse(content)
        self_names.concat(parser.account_names)
      end
    rescue CnBill::Error, Zip::Error, CSV::MalformedCSVError => e
      errors << "#{channel_label(channel)}: #{e.message}"
    end

    return Result.new(imports: [], cards: [], skipped: [], matched: [], errors: errors) if parsed.values.all?(&:empty?)

    accounts = resolve_accounts
    converter = CnBill::Converter.new(family: @family, cmb_account: accounts[:cmb], self_names: self_names)
    result = converter.convert(**parsed)

    ensure_exclusion_rules if result.cmb.any? { |r| r[:tags].to_s.include?(CnBill::LARGE_TRANSFER_TAG) || r[:tags].to_s.include?(CnBill::WEALTH_SWEEP_TAG) }

    imports = []
    { wechat: result.wallet, alipay: result.alipay, cmb: result.cmb }.each do |channel, rows|
      next if rows.empty?
      imports << create_import(channel, accounts[channel], rows)
    end

    Result.new(imports: imports, cards: result.cards, skipped: result.skipped, matched: result.matched, errors: errors)
  end

  private
    def channel_label(channel)
      I18n.t("cn_bill_imports.channels.#{channel}")
    end

    def resolve_accounts
      CnBill::CHANNELS.keys.index_with do |channel|
        id = @account_ids[channel]
        if id.present?
          @family.accounts.find(id)
        else
          name = CnBill::CHANNELS[channel][:account_name]
          # Prefix fallback: users rename accounts with suffixes like card
          # numbers ("招商银行储蓄卡(4876)"); auto-creating a second account
          # would split their history.
          @family.accounts.find_by(name: name) ||
            @family.accounts.where("name LIKE ?", "#{Account.sanitize_sql_like(name)}%").order(:created_at).first ||
            @family.accounts.create!(name: name, balance: 0, currency: @family.currency,
                                     accountable: Depository.new(subtype: "checking"))
        end
      end
    end

    def create_import(channel, account, rows)
      import = TransactionImport.new(family: @family, account: account)
      import.raw_file_str = CnBill.csv_for(rows)
      import.assign_attributes(
        col_sep: ",", rows_to_skip: 0, date_format: "%Y-%m-%d",
        amount_type_strategy: "signed_amount", signage_convention: "inflows_positive",
        date_col_label: "date", amount_col_label: "amount", name_col_label: "name",
        category_col_label: "category", tags_col_label: "tags", notes_col_label: "notes"
      )
      import.save!
      import.generate_rows_from_csv
      import.sync_mappings
      import.mappings.each { |m| m.update!(create_when_empty: true) if m.mappable.nil? && m.key.present? }
      import
    end

    # Idempotent: one active exclusion rule per tag. Created before publish so
    # the rules apply when the import syncs.
    def ensure_exclusion_rules
      {
        CnBill::LARGE_TRANSFER_TAG => "cn_bill_imports.large_transfer_rule_name",
        CnBill::WEALTH_SWEEP_TAG => "cn_bill_imports.wealth_sweep_rule_name"
      }.each do |tag_name, name_key|
        tag = @family.tags.find_or_create_by!(name: tag_name)
        existing = @family.rules.joins(:conditions).where(rule_conditions: { condition_type: "transaction_tag", value: tag.id })
                          .joins(:actions).where(rule_actions: { action_type: "exclude_transaction" }).exists?
        next if existing

        @family.rules.create!(
          name: I18n.t(name_key),
          resource_type: "transaction", active: true,
          conditions_attributes: [ { condition_type: "transaction_tag", operator: "=", value: tag.id } ],
          actions_attributes: [ { action_type: "exclude_transaction" } ]
        )
      end
    end
end
