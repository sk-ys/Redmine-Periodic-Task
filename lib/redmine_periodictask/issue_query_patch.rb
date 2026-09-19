module RedminePeriodictask
  # Adds the "Periodic task" filter and column to the issue list, saved
  # queries and the REST issues API (issues.json?periodictask=<id>).
  module IssueQueryPatch
    extend ActiveSupport::Concern

    included do
      include InstanceMethods

      alias_method :initialize_available_filters_without_periodictask, :initialize_available_filters
      alias_method :initialize_available_filters, :initialize_available_filters_with_periodictask

      alias_method :available_columns_without_periodictask, :available_columns
      alias_method :available_columns, :available_columns_with_periodictask

      alias_method :issues_without_periodictask, :issues
      alias_method :issues, :issues_with_periodictask

      alias_method :grouped_query_without_periodictask, :grouped_query
      alias_method :grouped_query, :grouped_query_with_periodictask
    end

    module InstanceMethods
      def initialize_available_filters_with_periodictask
        initialize_available_filters_without_periodictask
        add_available_filter 'periodictask', type: :list_optional, values: -> { periodictask_filter_values }
      end

      def available_columns_with_periodictask
        columns = available_columns_without_periodictask
        columns << PeriodictaskQueryColumn.new unless columns.any? { |c| c.name == :periodictask }
        columns
      end

      # "any"/"none" are the generic `*`/`!*` operators of a list_optional filter.
      # Redmine calls sql_for_#{field.tr('.', '_')}_field from Query#statement.
      # For field == 'periodictask', this method name must be sql_for_periodictask_field.
      def sql_for_periodictask_field(_field, operator, value)
        links = PeriodictaskIssue.table_name
        subquery = "SELECT #{links}.issue_id FROM #{links}"
        if %w[= !].include?(operator)
          ids = value.filter_map { |v| Integer(v.to_s, 10, exception: false) }
          return operator == '=' ? '1=0' : '1=1' if ids.empty?

          subquery += " WHERE #{links}.periodictask_id IN (#{ids.join(',')})"
        end
        negate = %w[! !*].include?(operator) ? 'NOT ' : ''
        "#{Issue.table_name}.id #{negate}IN (#{subquery})"
      end

      # Loads the generating task of the page's issues in one query (two with the
      # column or grouping): the recurrence marker needs the join row on every
      # list, the column and grouping need the task itself.
      def issues_with_periodictask(options = {})
        issues = issues_without_periodictask(options)
        links = PeriodictaskIssue.where(issue_id: issues.map(&:id)).index_by(&:issue_id)
        with_tasks = has_column?(:periodictask) || group_by_column.is_a?(PeriodictaskQueryColumn)
        tasks = with_tasks ? Periodictask.where(id: links.values.map(&:periodictask_id)).index_by(&:id) : {}
        issues.each do |issue|
          link = links[issue.id]
          issue.association(:periodictask_issue).target = link
          issue.association(:periodictask).target = link && tasks[link.periodictask_id] if with_tasks
        end
        issues
      end

      # Tasks the user may manage: the query project and its subprojects, or
      # every project when the query is global.
      def periodictask_filter_values
        tasks = Periodictask.visible.includes(:project)
        tasks = tasks.where(project_id: project.self_and_descendants.select(:id)) if project
        tasks.sort_by { |t| [t.project.lft, t.subject, t.id] }.map { |t| [t.subject, t.id.to_s, t.project.name] }
      end

      private

      # The GROUP BY statement yields task ids; hand back the tasks so the group
      # counts line up with the column's group_value.
      def grouped_query_with_periodictask(&)
        result = grouped_query_without_periodictask(&)
        if result.is_a?(Hash) && group_by_column.is_a?(PeriodictaskQueryColumn)
          tasks = Periodictask.where(id: result.keys.compact).index_by(&:id)
          result = result.transform_keys { |id| id && tasks[id.to_i] }
        end
        result
      end
    end
  end
end
