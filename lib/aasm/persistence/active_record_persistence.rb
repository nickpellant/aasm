require_relative 'base'

module AASM
  module Persistence
    module ActiveRecordPersistence
      # This method:
      #
      # * extends the model with ClassMethods
      # * includes InstanceMethods
      #
      # Adds
      #
      #   after_initialize :aasm_ensure_initial_state
      #
      # As a result, it doesn't matter when you define your methods - the following 2 are equivalent
      #
      #   class Foo < ActiveRecord::Base
      #     def aasm_write_state(state)
      #       "bar"
      #     end
      #     include AASM
      #   end
      #
      #   class Foo < ActiveRecord::Base
      #     include AASM
      #     def aasm_write_state(state)
      #       "bar"
      #     end
      #   end
      #
      def self.included(base)
        base.send(:include, AASM::Persistence::Base)
        base.send(:include, AASM::Persistence::ActiveRecordPersistence::InstanceMethods)

        base.after_initialize do
          aasm_ensure_initial_state
        end

        # ensure state is in the list of states
        base.validate :aasm_validate_states
      end

      module InstanceMethods

        # Writes <tt>state</tt> to the state column and persists it to the database
        #
        #   foo = Foo.find(1)
        #   foo.aasm.current_state # => :opened
        #   foo.close!
        #   foo.aasm.current_state # => :closed
        #   Foo.find(1).aasm.current_state # => :closed
        #
        # NOTE: intended to be called from an event
        def aasm_write_state(state, name=:default)
          old_value = read_attribute(self.class.aasm(name).attribute_name)
          aasm_write_attribute state, name

          success = if aasm_skipping_validations(name)
            value = aasm_raw_attribute_value(state, name)
            self.class.where(self.class.primary_key => self.id).update_all(self.class.aasm(name).attribute_name => value) == 1
          else
            self.save
          end
          unless success
            write_attribute(self.class.aasm(name).attribute_name, old_value)
            return false
          end

          true
        end

        # Writes <tt>state</tt> to the state column, but does not persist it to the database
        #
        #   foo = Foo.find(1)
        #   foo.aasm.current_state # => :opened
        #   foo.close
        #   foo.aasm.current_state # => :closed
        #   Foo.find(1).aasm.current_state # => :opened
        #   foo.save
        #   foo.aasm.current_state # => :closed
        #   Foo.find(1).aasm.current_state # => :closed
        #
        # NOTE: intended to be called from an event
        def aasm_write_state_without_persistence(state, name=:default)
          aasm_write_attribute(state, name)
        end

      private
        def aasm_enum(name=:default)
          case AASM::StateMachine[self.class][name].config.enum
            when false then nil
            when true then aasm_guess_enum_method(name)
            when nil then aasm_guess_enum_method(name) if aasm_column_looks_like_enum(name)
            else AASM::StateMachine[self.class][name].config.enum
          end
        end

        def aasm_column_looks_like_enum(name=:default)
          self.class.columns_hash[self.class.aasm(name).attribute_name.to_s].type == :integer
        end

        def aasm_guess_enum_method(name=:default)
          self.class.aasm(name).attribute_name.to_s.pluralize.to_sym
        end

        def aasm_skipping_validations(state_machine_name)
          AASM::StateMachine[self.class][state_machine_name].config.skip_validation_on_save
        end

        def aasm_write_attribute(state, name=:default)
          write_attribute(self.class.aasm(name).attribute_name, aasm_raw_attribute_value(state, name))
        end

        def aasm_raw_attribute_value(state, name=:default)
          if aasm_enum(name)
            self.class.send(aasm_enum(name))[state]
          else
            state.to_s
          end
        end

        # Ensures that if the aasm_state column is nil and the record is new
        # that the initial state gets populated before validation on create
        #
        #   foo = Foo.new
        #   foo.aasm_state # => nil
        #   foo.valid?
        #   foo.aasm_state # => "open" (where :open is the initial state)
        #
        #
        #   foo = Foo.find(:first)
        #   foo.aasm_state # => 1
        #   foo.aasm_state = nil
        #   foo.valid?
        #   foo.aasm_state # => nil
        #
        def aasm_ensure_initial_state
          AASM::StateMachine[self.class].keys.each do |state_machine_name|
            # checking via respond_to? does not work in Rails <= 3
            # if respond_to?(self.class.aasm(state_machine_name).attribute_name) && send(self.class.aasm(state_machine_name).attribute_name).blank? # Rails 4
            if attribute_names.include?(self.class.aasm(state_machine_name).attribute_name.to_s) && send(self.class.aasm(state_machine_name).attribute_name).blank?
              aasm(state_machine_name).enter_initial_state
            end
          end
        end

        def aasm_fire_event(state_machine_name, name, options, *args, &block)
          success = options[:persist] ? self.class.transaction(:requires_new => requires_new?(state_machine_name)) { super } : super

          if success && options[:persist]
            event = self.class.aasm(state_machine_name).state_machine.events[name]
            event.fire_callbacks(:after_commit, self, *args)
          end

          success
        end

        def requires_new?(state_machine_name)
          AASM::StateMachine[self.class][state_machine_name].config.requires_new_transaction
        end

        def aasm_validate_states
          AASM::StateMachine[self.class].keys.each do |state_machine_name|
            unless aasm_skipping_validations(state_machine_name)
              if aasm(state_machine_name).current_state && !aasm(state_machine_name).states.include?(aasm(state_machine_name).current_state)
                self.errors.add(AASM::StateMachine[self.class][state_machine_name].config.column , "is invalid")
              end
            end
          end
        end
      end # InstanceMethods

    end
  end # Persistence
end # AASM
