class MainController < ApplicationController

  @@store_codes = %w(FAN001 ALN001 AVE001 BEN001 BEY001 BLA001 EQQ001 FIT001 INN001 JEU001 LEA001 LIF001 OCE001 OME001 ONL001 PER001 PMG001 PUB001 PUR001 PUR002 REV001 ROU001 SEE001 SIM001 TES001 ULT002 ULT003 URE001 VIT001 AME001 TRU001)
  @@date_fmt = '%m/%d/%y'.freeze
  @@ship_kind = 'FULFILLMENT'.freeze

  def index
    @var = 'cool'
  end


  # this will take a dyna code form the params and run the program
  # it will return true if no errors
  # else it will return those records with errors
  # store code
  # start_date
  # end_date
  # dyna_send
  # ftp: true/false
  def export
    ap params

    csv_company = check_dyna_send(params[:dyna_send])
    raise ArgumentError, 'Bad dyna_send value' if csv_company.nil?

    upload_ftp = ftp

    stores = ShipStation::Store.where(dyna_code: params[:store_code])
    if stores.nil? or stores.count < 1
      raise 'Invalid Store Specified, No Dynamics Code'
    end

    idList = stores.collect{|s| s.id;}
    start_date = start_date.to_date
    end_date = end_date.nil?  ? start_date : (end_date.to_date rescue Date.today)

      # @type [Dynamics::ShipmentHelper] helper
      helper = DynamicsHelper::ShipmentHelper.getClientFromCode(store_code)

      out_dir = File.expand_path("dynamics/shipexp/#{store_code}", './external_files')
      if Dir.exists?(out_dir) == false
        FileUtils.mkdir_p(out_dir)
      end
      order_total = 0
      dyn_name = "#{out_dir}/shipments-#{store_code}-#{start_date.strftime('%Y%m%d')}-#{end_date.strftime('%Y%m%d')}.pro"
      dyn_csv = CSV.open(dyn_name, 'w',{:force_quotes=>true})

      dyn_csv << %w(ShipmentUUID ClientID Date Status ShipToName ShipToAddress1 ShipToAddress2 ShipToCity ShipToState ShipToZIP ShipToCountry TrackingNo OrderNo ShipmentMethod Reshipment Billable Kind CustomerSKU Quantity Kitted Insure SigRequired Delete Company PriceLevel)

      ship_wheresql=<<eos
        (ship_station_shipments.void_date is null)
    and (ship_station_shipments.ship_date between ? and ?)
    and (   (ship_station_orders.ship_date between ? and ? )  and
                ( (ship_station_orders.store_id in (?)) or  (ship_station_orders.store_id = 45506 and ship_station_orders.custom_field1 = '#{store_code}'))
        )
eos

      ShipStation::Shipment.includes(:order).where(ship_wheresql,
                               start_date.to_time.utc.strftime('%Y-%m-%d 00:00:00'),
                               end_date.to_time.utc.strftime('%Y-%m-%d 23:59:59'),
                               start_date.to_time.utc.strftime('%Y-%m-%d 00:00:00'),
                               end_date.to_time.utc.strftime('%Y-%m-%d 23:59:59'),
                               idList

      ).find_each(:batch_size=>100) do |the_order|
        # skip problem orders with no items
        next if the_order.order.nil?
        next if the_order.order.items.nil? || the_order.order.items.length < 1
        next if the_order.order.id == 88211634
        next if the_order.order.id == 88851901
        next if the_order.order.id == 89000309

        order_total = order_total + 1
        service = ShipStation::ShippingService.find(the_order.shipping_service_id) rescue nil
        sname = service.name rescue 'UNKNOWN'
        is_billable = true
        is_reshipment = false


        if !the_order.order.custom_field2.nil? && !the_order.order.custom_field2.empty?
          if  the_order.order.custom_field2.include?('RSNB') || the_order.order.custom_field2.include?('RSB')
            is_reshipment = true
            is_billable = !the_order.order.custom_field2.include?('RSNB') ? 'true' : 'false'
          end
        end


        order_info = {
            'ShipmentUUID' => the_order.id,
            'ClientID' => store_code,
            'Date' => the_order.ship_date.to_time.utc.strftime(@@date_fmt),
            'Status' => 'Shipped',
            'ShipToName' => the_order.name,
            'ShipToAddress1' => the_order.street1,
            'ShipToAddress2' => the_order.street2,
            'ShipToCity' => the_order.city,
            'ShipToState' => the_order.state,
            'ShipToZIP' => the_order.postal_code,
            'ShipToCountry' => the_order.country_code,
            'TrackingNo' => the_order.tracking_number,
            'OrderNo' => the_order.order.order_number,
            'ShipmentMethod' => sname,
            'Reshipment' => is_reshipment ? "true" : "false",
            'Billable' => is_billable ? "true" : "false",
            'Kind' => @@ship_kind,
            'Kitted' => 'false',
            'Insure' => 'false',
            'SigRequired' => 'false',
            'Delete' => 'false',
            'Company' => csv_company,
            'PriceLevel' => helper.price_level
        }


        item_count = 0

        item_list = Array.new()

        # Add Line Items First
        the_order.order.items.each do |the_item|
          next if the_item.create_date < the_order.order.create_date
          item_info = helper.mapsku(the_order,the_item.sku,the_item.quantity)
          if item_info[:sku] == 'NULL' || item_info[:quantity] == 0
            next  # skip if the sku is null or the quantity is 0
          end
          if !item_info[:sku].is_a?(Array)
            item_count = item_count + item_info[:quantity]
            item_list << item_info
            dyn_csv << [
                order_info['ShipmentUUID'],
                order_info['ClientID'],
                order_info['Date'],
                order_info['Status' ],
                order_info['ShipToName'],
                order_info['ShipToAddress1'],
                order_info['ShipToAddress2'],
                order_info['ShipToCity'],
                order_info['ShipToState'],
                order_info['ShipToZip'],
                order_info['ShipToCountry'],
                order_info['TrackingNo'],
                order_info['OrderNo'],
                order_info['ShipmentMethod'],
                order_info['Reshipment'],
                order_info['Billable'],
                order_info['Kind'],
                item_info[:sku],
                item_info[:quantity],
                order_info['Kitted'],
                order_info['Insure'],
                order_info['SigRequired'],
                order_info['Delete'],
                csv_company,
                order_info['PriceLevel']
            ]
          else
            for i in 0..item_info[:sku].length-1 do
              item_count = item_count + item_info[:quantity][i]
              item_list << item_info
              dyn_csv << [
                  order_info['ShipmentUUID'],
                  order_info['ClientID'],
                  order_info['Date'],
                  order_info['Status' ],
                  order_info['ShipToName'],
                  order_info['ShipToAddress1'],
                  order_info['ShipToAddress2'],
                  order_info['ShipToCity'],
                  order_info['ShipToState'],
                  order_info['ShipToZip'],
                  order_info['ShipToCountry'],
                  order_info['TrackingNo'],
                  order_info['OrderNo'],
                  order_info['ShipmentMethod'],
                  order_info['Reshipment'],
                  order_info['Billable'],
                  order_info['Kind'],
                  item_info[:sku][i],
                  item_info[:quantity][i],
                  order_info['Kitted'],
                  order_info['Insure'],
                  order_info['SigRequired'],
                  order_info['Delete'],
                  csv_company,
                  order_info['PriceLevel']
              ]

            end
          end
        end



        shipType = helper.shiptype(the_order,item_list,item_count)
        if !shipType.nil?
          dyn_csv << [
              order_info['ShipmentUUID'],
              order_info['ClientID'],
              order_info['Date'],
              order_info['Status' ],
              order_info['ShipToName'],
              order_info['ShipToAddress1'],
              order_info['ShipToAddress2'],
              order_info['ShipToCity'],
              order_info['ShipToState'],
              order_info['ShipToZip'],
              order_info['ShipToCountry'],
              order_info['TrackingNo'],
              order_info['OrderNo'],
              order_info['ShipmentMethod'],
              order_info['Reshipment'],
              order_info['Billable'],
              order_info['Kind'],
              shipType,
              1,
              order_info['Kitted'],
              order_info['Insure'],
              order_info['SigRequired'],
              order_info['Delete'],
              csv_company,
              order_info['PriceLevel']
          ]
        end

        pkType = helper.packtype(the_order,item_list,item_count)
        dyn_csv << [
            order_info['ShipmentUUID'],
            order_info['ClientID'],
            order_info['Date'],
            order_info['Status' ],
            order_info['ShipToName'],
            order_info['ShipToAddress1'],
            order_info['ShipToAddress2'],
            order_info['ShipToCity'],
            order_info['ShipToState'],
            order_info['ShipToZip'],
            order_info['ShipToCountry'],
            order_info['TrackingNo'],
            order_info['OrderNo'],
            order_info['ShipmentMethod'],
            order_info['Reshipment'],
            order_info['Billable'],
            order_info['Kind'],
            pkType,
            1,
            order_info['Kitted'],
            order_info['Insure'],
            order_info['SigRequired'],
            order_info['Delete'],
            csv_company,
            order_info['PriceLevel']
        ]


      end

      dyn_csv.close
      if order_total < 1
        ap "No Orders Exported"
        File.delete(dyn_name) if File.exist?(dyn_name)
      else
        ap "Exported #{order_total} Order(s)"
        if upload_ftp == true

          ap "Sending to FTP..."
          Net::FTP.open('dynagp.etrackerplus.com', 'dynamics.dynagp', 'y5VhGmtg') do |ftp|
            ftp.chdir('/Export/Output')
            ftp.put(dyn_name)
          end

        end
        puts "Done!\n\n"
      end

    end

    }

  end

  def check_dyna_code dyna_send
    if dyna_send == 'LIVE'
      return 'SHPO'
    elsif dyna_send == 'QA'
      return 'QASHP'
    elsif dyna_send == 'TEST'
      return 'TSHPO'
    end
  end


end
