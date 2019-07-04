# Copyright (C) 2012-2016 Zammad Foundation, http://zammad-foundation.org/

class Tag < ApplicationModel

  belongs_to :tag_object, class_name: 'Tag::Object', optional: true
  belongs_to :tag_item,   class_name: 'Tag::Item', optional: true

  # the noop is needed since Layout/EmptyLines detects
  # the block commend below wrongly as the measurement of
  # the wanted indentation of the rubocop re-enabling above
  def noop; end

=begin

add tags for certain object

  Tag.tag_add(
    object: 'Ticket',
    o_id: ticket.id,
    item: 'some tag',
    created_by_id: current_user.id,
  )

=end

  def self.tag_add(data)
    data[:item].strip!

    # lookups
    if data[:object]
      tag_object_id = Tag::Object.lookup_by_name_and_create(data[:object]).id
    end
    if data[:item]
      tag_item_id = Tag::Item.lookup_by_name_and_create(data[:item]).id
    end

    # return if duplicate
    current_tags = tag_list(data)
    return true if current_tags.include?(data[:item])

    # create history
    Tag.create(
      tag_object_id: tag_object_id,
      tag_item_id:   tag_item_id,
      o_id:          data[:o_id],
      created_by_id: data[:created_by_id],
    )

    # touch reference
    touch_reference_by_params(data)
    true
  end

=begin

remove tags of certain object

  Tag.tag_remove(
    object: 'Ticket',
    o_id: ticket.id,
    item: 'some tag',
    created_by_id: current_user.id,
  )

or by ids

  Tag.tag_remove(
    tag_object_id: 123,
    o_id: ticket.id,
    tag_item_id: 123,
    created_by_id: current_user.id,
  )

=end

  def self.tag_remove(data)

    # lookups
    if data[:object]
      data[:tag_object_id] = Tag::Object.lookup_by_name_and_create(data[:object]).id
    else
      data[:object] = Tag::Object.lookup(id: data[:tag_object_id]).name
    end
    if data[:item]
      data[:item].strip!
      data[:tag_item_id] = Tag::Item.lookup_by_name_and_create(data[:item]).id
    end

    # create history
    result = Tag.where(
      tag_object_id: data[:tag_object_id],
      tag_item_id:   data[:tag_item_id],
      o_id:          data[:o_id],
    )
    result.each(&:destroy)

    # touch reference
    touch_reference_by_params(data)
    true
  end

=begin

remove all tags of certain object

  Tag.tag_destroy(
    object: 'Ticket',
    o_id: ticket.id,
    created_by_id: current_user.id,
  )

=end

  def self.tag_destroy(data)

    # lookups
    if data[:object]
      data[:tag_object_id] = Tag::Object.lookup_by_name_and_create(data[:object]).id
    else
      data[:object] = Tag::Object.lookup(id: data[:tag_object_id]).name
    end

    # create history
    result = Tag.where(
      tag_object_id: data[:tag_object_id],
      o_id:          data[:o_id],
    )
    result.each(&:destroy)
    true
  end

=begin

tag list for certain object

  tags = Tag.tag_list(
    object: 'Ticket',
    o_id: ticket.id,
  )

returns

  ['tag 1', 'tag2', ...]

=end

  def self.tag_list(data)
    Tag.joins(:tag_item, :tag_object)
       .where(o_id: data[:o_id], tag_objects: { name: data[:object] })
       .order(:id)
       .pluck('tag_items.name')
  end

  class Object < ApplicationModel
    validates :name, presence: true

=begin

lookup by name and create tag item

  tag_object = Tag::Object.lookup_by_name_and_create('some tag')

=end

    def self.lookup_by_name_and_create(name)
      name.strip!

      tag_object = Tag::Object.lookup(name: name)
      return tag_object if tag_object

      Tag::Object.create(name: name)
    end

  end

  class Item < ApplicationModel
    validates   :name, presence: true
    before_save :fill_namedowncase

=begin

lookup by name and create tag item

  tag_item = Tag::Item.lookup_by_name_and_create('some tag')

=end

    def self.lookup_by_name_and_create(name)
      name.strip!

      tag_item = Tag::Item.lookup(name: name)
      return tag_item if tag_item

      Tag::Item.create(name: name)
    end

=begin

rename tag items

  Tag::Item.rename(
    id: existing_tag_item_to_rename,
    name: 'new tag item name',
    updated_by_id: current_user.id,
  )

=end

    def self.rename(data)

      new_tag_name         = data[:name].strip
      old_tag_item         = Tag::Item.find(data[:id])
      already_existing_tag = Tag::Item.lookup(name: new_tag_name)

      # check if no remame is needed
      return true if new_tag_name == old_tag_item.name

      # merge old with new tag if already existing
      if already_existing_tag

        # re-assign old tag to already existing tag
        Tag.where(tag_item_id: old_tag_item.id).each do |tag|

          # check if tag already exists on object
          if Tag.find_by(tag_object_id: tag.tag_object_id, o_id: tag.o_id, tag_item_id: already_existing_tag.id)
            Tag.tag_remove(
              tag_object_id: tag.tag_object_id,
              o_id:          tag.o_id,
              tag_item_id:   old_tag_item.id,
            )
            next
          end

          # re-assign
          tag_object = Tag::Object.lookup(id: tag.tag_object_id)
          tag.tag_item_id = already_existing_tag.id
          tag.save

          # touch reference objects
          Tag.touch_reference_by_params(
            object: tag_object.name,
            o_id:   tag.o_id,
          )
        end

        # delete not longer used tag
        old_tag_item.destroy
        return true
      end

      update_referenced_objects(old_tag_item.name, new_tag_name)

      # update new tag name
      old_tag_item.name = new_tag_name
      old_tag_item.save

      # touch reference objects
      Tag.where(tag_item_id: old_tag_item.id).each do |tag|
        tag_object = Tag::Object.lookup(id: tag.tag_object_id)
        Tag.touch_reference_by_params(
          object: tag_object.name,
          o_id:   tag.o_id,
        )
      end

      true
    end

=begin

remove tag item (destroy with reverences)

  Tag::Item.remove(id)

=end

    def self.remove(id)

      # search for references, destroy and touch
      Tag.where(tag_item_id: id).each do |tag|
        tag_object = Tag::Object.lookup(id: tag.tag_object_id)
        tag.destroy
        Tag.touch_reference_by_params(
          object: tag_object.name,
          o_id:   tag.o_id,
        )
      end
      Tag::Item.find(id).destroy
      true
    end

    def fill_namedowncase
      self.name_downcase = name.downcase
      true
    end

=begin

  Update referenced objects such as triggers, overviews, schedulers, and postmaster filters

  Specifically, the following fields are updated:

  Overview.condition
  Trigger.condition   Trigger.perform
  Job.condition       Job.perform
                      PostmasterFilter.perform

=end

    def self.update_referenced_objects(old_name, new_name)
      objects = Overview.all + Trigger.all + Job.all + PostmasterFilter.all

      objects.each do |object|
        changed = false
        if object.has_attribute?(:condition)
          changed |= update_condition_hash object.condition, old_name, new_name
        end
        if object.has_attribute?(:perform)
          changed |= update_condition_hash object.perform, old_name, new_name
        end
        object.save if changed
      end
    end

    def self.update_condition_hash(hash, old_name, new_name)
      changed = false
      hash.each do |key, condition|
        next if %w[ticket.tags x-zammad-ticket-tags].exclude? key
        next if condition[:value].split(', ').exclude? old_name

        condition[:value] = update_name(condition[:value], old_name, new_name)
        changed = true
      end
      changed
    end

    def self.update_name(condition, old_name, new_name)
      tags = condition.split(', ')
      return new_name if tags.size == 1

      tags = tags.map { |t| t == old_name ? new_name : t }
      tags.join(', ')
    end

  end

end
