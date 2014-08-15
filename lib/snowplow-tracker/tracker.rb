# Copyright (c) 2013-2014 Snowplow Analytics Ltd. All rights reserved.
#
# This program is licensed to you under the Apache License Version 2.0,
# and you may not use this file except in compliance with the Apache License Version 2.0.
# You may obtain a copy of the Apache License Version 2.0 at http://www.apache.org/licenses/LICENSE-2.0.
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the Apache License Version 2.0 is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the Apache License Version 2.0 for the specific language governing permissions and limitations there under.

# Author:: Alex Dean, Fred Blundun (mailto:support@snowplowanalytics.com)
# Copyright:: Copyright (c) 2013-2014 Snowplow Analytics Ltd
# License:: Apache License Version 2.0

require 'contracts'
require 'set'
include Contracts

require 'uuid'

module SnowplowTracker

  class Tracker

    @@required_transaction_keys =   Set.new(%w(order_id total_value))
    @@recognised_transaction_keys = Set.new(%w(order_id total_value affiliation tax_value shipping city state country currency))

    @@Transaction = lambda { |x|
      return false unless x.class == Hash
      transaction_keys = Set.new(x.keys)
      @@required_transaction_keys.subset? transaction_keys and
        transaction_keys.subset? @@recognised_transaction_keys
    }

    @@required_item_keys =   Set.new(%w(sku price quantity))
    @@recognised_item_keys = Set.new(%w(sku price quantity name category context))

    @@Item = lambda { |x|
      return false unless x.class == Hash
      item_keys = Set.new(x.keys)
      @@required_item_keys.subset? item_keys and
        item_keys.subset? @@recognised_item_keys
    }

    @@required_augmented_item_keys =   Set.new(%w(sku price quantity tstamp order_id))
    @@recognised_augmented_item_keys = Set.new(%w(sku price quantity name category context tstamp order_id currency))

    @@AugmentedItem = lambda { |x|
      return false unless x.class == Hash
      augmented_item_keys = Set.new(x.keys)
      @@required_augmented_item_keys.subset? augmented_item_keys and
        augmented_item_keys.subset? @@recognised_augmented_item_keys
    }

    @@SelfDescribingJson = Or[{
      schema: String,
      data: Any
    }, {
      'schema' => String,
      'data' => Any
    }]

    @@ContextsInput = ArrayOf[@@SelfDescribingJson]

    @@version = TRACKER_VERSION
    @@default_encode_base64 = true
    @@default_platform = 'srv'
    @@supported_platforms = ['pc', 'tv', 'mob', 'cnsl', 'iot']
    @@http_errors = ['host not found',
                     'No address associated with name',
                     'No address associated with hostname']

    @@base_schema_path = "iglu:com.snowplowanalytics.snowplow"
    @@schema_tag = "jsonschema"
    @@context_schema = "#{@@base_schema_path}/contexts/#{@@schema_tag}/1-0-0"
    @@unstruct_event_schema = "#{@@base_schema_path}/unstruct_event/#{@@schema_tag}/1-0-0"

    Contract Emitter, Maybe[String], Maybe[String], Bool => Tracker
    def initialize(emitter, namespace=nil, app_id=nil, encode_base64=@@default_encode_base64)
      @emitter = emitter
      @standard_nv_pairs = {
        'tna' => namespace,
        'tv'  => @@version,
        'p'   => @@default_platform,
        'aid' => app_id
      }
      @config = {
        'encode_base64' => encode_base64
      }
      @uuid = UUID.new
      self
    end

    # Generates a type-4 UUID to identify this event
    Contract nil => String
    def get_event_id()
      @uuid.generate
    end

    # Generates the timestamp (in milliseconds) to be attached to each event
    #
    Contract nil => Num
    def get_timestamp
      (Time.now.to_f * 1000).to_i
    end

    # Builds a self-describing JSON from an array of custom contexts
    #
    Contract @@ContextsInput => @@SelfDescribingJson
    def build_context(context)
      {
        schema: @@context_schema,
        data: context
      }
    end

    # Setter methods

    # Specify the platform
    #
    Contract String => Tracker
    def set_platform(value)
      if @@supported_platforms.include?(value)
        @standard_nv_pairs['p'] = value
      else
        raise "#{value} is not a supported platform"
      end

      self
    end

    # Set the business-defined user ID for a user
    #
    Contract String => Tracker
    def set_user_id(user_id)
      @standard_nv_pairs['uid'] = user_id
      self
    end

    # Set the screen resolution for a device
    #
    Contract Num, Num => Tracker
    def set_screen_resolution(width, height)
      @standard_nv_pairs['res'] = "#{width}x#{height}"
      self
    end

    # Set the dimensions of the current viewport
    #
    Contract Num, Num => Tracker
    def set_viewport(width, height)
      @standard_nv_pairs['vp'] = "#{width}x#{height}"
      self
    end

    # Set the color depth of the device in bits per pixel
    #
    Contract Num => Tracker
    def set_color_depth(depth)
      @standard_nv_pairs['cd'] = depth
      self
    end

    # Set the timezone field
    #
    Contract String => Tracker
    def set_timezone(timezone)
      @standard_nv_pairs['tz'] = timezone
      self
    end

    # Set the language field
    #
    Contract String => Tracker
    def set_lang(lang)
      @standard_nv_pairs['lang'] = lang
      self
    end

    # Tracking methods

    # Attaches all the fields in @standard_nv_pairs to the request
    #  Only attaches the context vendor if the event has a custom context
    #
    Contract Payload => nil
    def track(pb)
      pb.add_dict(@standard_nv_pairs)
      pb.add('eid', get_event_id())
      @emitter.input(pb.context)

      nil
    end

    # Log a visit to this page
    #
    Contract String, Maybe[String], Maybe[String], Maybe[@@ContextsInput] => Tracker
    def track_page_view(page_url, page_title=nil, referrer=nil, context=nil, tstamp=nil)
      pb = Payload.new
      pb.add('e', 'pv')
      pb.add('url', page_url)
      pb.add('page', page_title)
      pb.add('refr', referrer)
      unless context.nil?
        pb.add_json(build_context(context), @config['encode_base64'], 'cx', 'co')
      end

      if tstamp.nil?
        tstamp = get_timestamp
      end
      pb.add('dtm', tstamp)
      track(pb)

      self
    end

    # Track a single item within an ecommerce transaction
    #   Not part of the public API
    #
    Contract @@AugmentedItem => self
    def track_ecommerce_transaction_item(argmap)
      pb = Payload.new
      pb.add('e', 'ti')
      pb.add('ti_id', argmap['order_id'])
      pb.add('ti_sk', argmap['sku'])
      pb.add('ti_pr', argmap['price'])
      pb.add('ti_qu', argmap['quantity'])
      pb.add('ti_nm', argmap['name'])
      pb.add('ti_ca', argmap['category'])
      pb.add('ti_cu', argmap['currency'])
      unless argmap['context'].nil?
        pb.add_json(build_context(argmap['context']), @config['encode_base64'], 'cx', 'co')
      end
      pb.add('dtm', argmap['tstamp'])
      track(pb)

      self
    end

    # Track an ecommerce transaction and all the items in it
    #
    Contract @@Transaction, ArrayOf[@@Item], Maybe[@@ContextsInput], Maybe[Num] => Tracker
    def track_ecommerce_transaction(transaction, items,
                                    context=nil, tstamp=nil)
      pb = Payload.new
      pb.add('e', 'tr')
      pb.add('tr_id', transaction['order_id'])
      pb.add('tr_tt', transaction['total_value'])
      pb.add('tr_af', transaction['affiliation'])
      pb.add('tr_tx', transaction['tax_value'])
      pb.add('tr_sh', transaction['shipping'])
      pb.add('tr_ci', transaction['city'])
      pb.add('tr_st', transaction['state'])
      pb.add('tr_co', transaction['country'])
      pb.add('tr_cu', transaction['currency'])
      unless context.nil?
        pb.add_json(build_context(context), @config['encode_base64'], 'cx', 'co')
      end

      if tstamp.nil?
        tstamp = get_timestamp
      end
      pb.add('dtm', tstamp)

      track(pb)

      for item in items
        item['tstamp'] = tstamp
        item['order_id'] = transaction['order_id']
        item['currency'] = transaction['currency']
        track_ecommerce_transaction_item(item)
      end

      self
    end

    # Track a structured event
    #
    Contract String, String, Maybe[String], Maybe[String], Maybe[Num], Maybe[@@ContextsInput], Maybe[Num] => Tracker
    def track_struct_event(category, action, label=nil, property=nil, value=nil, context=nil, tstamp=nil)
      pb = Payload.new
      pb.add('e', 'se')
      pb.add('se_ca', category)
      pb.add('se_ac', action)
      pb.add('se_la', label)
      pb.add('se_pr', property)
      pb.add('se_va', value)
      unless context.nil?
        pb.add_json(build_context(context), @config['encode_base64'], 'cx', 'co')
      end
      if tstamp.nil?
        tstamp = get_timestamp
      end
      pb.add('dtm', tstamp)
      track(pb)

      self
    end

    # Track a screen view event
    #
    Contract Maybe[String], Maybe[String],  Maybe[@@ContextsInput], Maybe[Num] => Tracker
    def track_screen_view(name=nil, id=nil, context=nil, tstamp=nil)
      screen_view_properties = {}
      unless name.nil? 
        screen_view_properties['name'] = name
      end
      unless id.nil? 
        screen_view_properties['id'] = id
      end
      screen_view_schema = "#{@@base_schema_path}/screen_view/#{@@schema_tag}/1-0-0"
      event_json = {schema: screen_view_schema, data: screen_view_properties}

      self.track_unstruct_event(event_json, context, tstamp)

      self
    end

    # Track an unstructured event
    #
    Contract @@SelfDescribingJson, Maybe[@@ContextsInput], Maybe[Num] => Tracker
    def track_unstruct_event(event_json, context=nil, tstamp=nil)
      pb = Payload.new
      pb.add('e', 'ue')
      
      envelope = {
        schema: @@unstruct_event_schema,
        data: event_json
      }
      pb.add_json(envelope, @config['encode_base64'], 'ue_px', 'ue_pr')

      unless context.nil?
        pb.add_json(build_context(context), @config['encode_base64'], 'cx', 'co')
      end

      if tstamp.nil?
        tstamp = get_timestamp
      end
      pb.add('dtm', tstamp)

      track(pb)

      self
    end

    private :get_timestamp,
            :build_context,
            :track,
            :track_ecommerce_transaction_item

  end

end
