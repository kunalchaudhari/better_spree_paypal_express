class AddBillingAgreementColumnsToSpreeOrders < ActiveRecord::Migration
  def change
    add_column :spree_orders, :billing_type, :string
    add_column :spree_orders, :billing_agreement_description, :string
  end
end
