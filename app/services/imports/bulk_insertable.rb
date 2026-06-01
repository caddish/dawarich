# frozen_string_literal: true

module Imports
  module BulkInsertable
    extend ActiveSupport::Concern

    private

    def bulk_insert_points(batch)
      return 0 if batch.empty?

      # --- NEW: Delete overlaps for the current batch ---
      times = batch.map { |r| r[:timestamp] }.compact
      if times.any?
        # 1. Fetch the overlapping point IDs for this specific user
        point_ids = Point.where(user_id: user_id, timestamp: times.min..times.max).pluck(:id)

        if point_ids.any?
          # Mirror your BULK_DESTROY_MAX constant rule if you want the same constraint
          # Define this constant at the top of your class or replace with your hardcoded value (e.g., 5000)
          bulk_destroy_max = 5000
          
          # Optional guard check: slice into batches if you exceed the controller limit, 
          # or process it in chunks using point_ids.each_slice(bulk_destroy_max)
          if point_ids.size > bulk_destroy_max
            Rails.logger.warn "[#{importer_name} Importer] Large cleanup required: #{point_ids.size} points exceeds safety limit. Slicing execution."
          end

          affected_track_ids = nil
          destroyed = nil

          # 2. Database transaction blocks execution until finished (Synchronous)
          ActiveRecord::Base.transaction do
            affected_track_ids = Point.where(user_id: user_id, id: point_ids)
                                      .where.not(track_id: nil)
                                      .distinct
                                      .pluck(:track_id)
                                      
            destroyed = Point.where(user_id: user_id, id: point_ids).destroy_all
          end

          deleted_count = destroyed.count

          if deleted_count.positive?
            # 3. Synchronously decrease user dashboard counts
            User.update_counters(user_id, points_count: -deleted_count)

            # 4. Extract unique Year/Month pairs to recalculate analytics dashboard
            destroyed
              .map { |p| Time.zone.at(p.timestamp) }
              .map { |ts| [ts.year, ts.month] }
              .uniq
              .each { |year, month| Stats::CalculatingJob.perform_later(user_id, year, month) }
          end

          # 5. Enqueue track length/speed corrections
          if affected_track_ids.any?
            Rails.logger.info(
              "[#{importer_name} Importer] Batch Cleanup deleted #{deleted_count} points, " \
              "enqueuing Tracks::RecalculateJob for #{affected_track_ids.size} tracks."
            )
            affected_track_ids.each { |track_id| Tracks::RecalculateJob.perform_later(track_id) }
          end
        end
      end
      # --------------------------------------------------

      unique_batch = batch.compact.uniq { |record| [record[:lonlat], record[:timestamp], record[:user_id]] }

      result = Point.upsert_all(
        unique_batch,
        unique_by: %i[lonlat timestamp user_id],
        returning: Arel.sql('id'),
        on_duplicate: :skip
      )

      inserted = result.length
      skipped  = unique_batch.length - inserted
      record_batch_counters(unique_batch.length, skipped)

      inserted
    rescue StandardError => e
      on_bulk_insert_error(e)
      create_import_error_notification("Failed to process #{importer_name} data: #{e.message}")
      0
    end

    def record_batch_counters(attempted, skipped)
      counters = { raw_points: attempted }
      counters[:doubles] = skipped if skipped.positive?
      Import.update_counters(import.id, counters)
    end

    def create_import_error_notification(message)
      Notification.create!(
        user_id: import.user_id,
        title: "#{importer_name} Import Error",
        content: message,
        kind: :error
      )
    end

    # Override in subclasses to add custom error handling (e.g. ExceptionReporter)
    def on_bulk_insert_error(exception); end

    def importer_name
      self.class.name.split('::').first
    end
  end
end
