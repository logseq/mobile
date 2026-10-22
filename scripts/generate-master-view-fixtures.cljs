(ns generate-master-view-fixtures
  (:require [clojure.string :as string]
            [datascript.core :as d]
            [logseq.db.common.view :as view]
            ["fs" :as fs]))

(def master-commit "05c3ae73e08498e9e20f1b11c3eac5525e5e588d")
(defn uuid-for [n]
  (uuid (str "30000000-0000-4000-8000-" (string/join (repeat (- 12 (count (str n))) "0")) n)))

(def schema
  {:block/uuid {:db/unique :db.unique/identity}
   :db/ident {:db/unique :db.unique/identity}
   :block/page {:db/valueType :db.type/ref}
   :block/parent {:db/valueType :db.type/ref}
   :block/title {:db/index true}
   :block/created-at {:db/index true}
   :block/updated-at {:db/index true}
   :logseq.property/hide? {:db/index true}
   :logseq.property/built-in? {:db/index true}
   :logseq.property/deleted-at {:db/index true}
   :logseq.property.recycle/original-parent {:db/valueType :db.type/ref}
   :block/refs {:db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
   :block/tags {:db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
   :logseq.property.class/extends {:db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
   :block/closed-value-property {:db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
   :logseq.property/query {:db/valueType :db.type/ref}
   :logseq.property/view-for {:db/valueType :db.type/ref}
   :logseq.property.view/type {:db/valueType :db.type/ref}
   :logseq.property/created-from-property {:db/valueType :db.type/ref}
   :user.property/text {:db/valueType :db.type/ref}
   :user.property/number {:db/valueType :db.type/ref}
   :user.property/many {:db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
   :user.property/date {:db/valueType :db.type/ref}
   :user.property/choice {:db/valueType :db.type/ref}})

(def properties
  [{:db/id 950019 :db/ident :block/title :logseq.property/type :string}
   {:db/id 950018 :block/uuid (uuid-for 18) :db/ident :user.property/conformance-row? :logseq.property/type :checkbox}
   {:db/id 950010 :db/ident :user.property/text :logseq.property/type :default}
   {:db/id 950011 :db/ident :user.property/number :logseq.property/type :number}
   {:db/id 950012 :db/ident :user.property/many :logseq.property/type :number :db/cardinality :db.cardinality/many}
   {:db/id 950013 :db/ident :user.property/date :logseq.property/type :date}
   {:db/id 950014 :db/ident :user.property/choice :logseq.property/type :default}
   {:db/id 950015 :db/ident :user.property/flag :logseq.property/type :checkbox}
   {:db/id 950016 :db/ident :user.property/time :logseq.property/type :datetime}
   {:db/id 950017 :db/ident :user.property/raw :logseq.property/type :any}])

(def data
  (concat
   properties
   [{:db/id 950000 :block/uuid (uuid-for 1) :block/title "Fixture page" :block/name "fixture page"}
    {:db/id 950001 :block/uuid (uuid-for 2) :block/title "Fixture query" :block/page 950000 :block/parent 950000 :block/order "a0" :logseq.property/query 950002}
    {:db/id 950002 :block/uuid (uuid-for 3) :block/title "{:query [:find (pull ?b [*]) :where [?b :user.property/conformance-row? true]]}" :block/page 950000 :block/parent 950000 :block/order "a1"}
    {:db/id 950003 :block/uuid (uuid-for 4) :block/title "Fixture view" :block/page 950000 :block/parent 950000 :block/order "a2"
     :logseq.property/view-for 950001 :logseq.property.view/feature-type :query-result :logseq.property.view/type 950004}
    {:db/id 950004 :db/ident :logseq.property.view/type.table}
    {:db/id 950005 :db/ident :logseq.property/empty-placeholder}
    {:db/id 950006 :block/uuid (uuid-for 6) :block/name "fixture tag" :block/title "Fixture tag" :block/tags [950009]}
    {:db/id 950007 :block/uuid (uuid-for 7) :block/title "Tag view" :logseq.property/view-for 950006 :logseq.property.view/feature-type :class-objects :logseq.property.view/type 950004}
    {:db/id 950008 :block/uuid (uuid-for 8) :block/title "Property view" :logseq.property/view-for 950018 :logseq.property.view/feature-type :property-objects :logseq.property.view/type 950004}
    {:db/id 950009 :block/uuid (uuid-for 9) :db/ident :logseq.class/Tag :block/name "tag" :block/title "Tag"}
    {:db/id 950020 :block/uuid (uuid-for 20) :block/title "APPLE"}
    {:db/id 950021 :block/uuid (uuid-for 21) :block/title "apple"}
    {:db/id 950022 :block/uuid (uuid-for 22) :block/title "Orange"}
    {:db/id 950023 :block/uuid (uuid-for 23) :block/title "ΜΗΛΟ"}
    {:db/id 950024 :block/uuid (uuid-for 24) :block/title ""}
    {:db/id 950030 :block/uuid (uuid-for 30) :logseq.property/value 0}
    {:db/id 950031 :block/uuid (uuid-for 31) :logseq.property/value 10}
    {:db/id 950032 :block/uuid (uuid-for 32) :logseq.property/value -2.5}
    {:db/id 950033 :block/uuid (uuid-for 33) :logseq.property/value 10}
    {:db/id 950040 :block/uuid (uuid-for 40) :block/title "October 1" :block/journal-day 20261001}
    {:db/id 950041 :block/uuid (uuid-for 41) :block/title "October 3" :block/journal-day 20261003}
    {:db/id 950050 :block/uuid (uuid-for 50) :block/title "Zulu" :db/ident :user.choice/zulu :block/order "a0" :block/closed-value-property 950014}
    {:db/id 950051 :block/uuid (uuid-for 51) :block/title "Alpha" :db/ident :user.choice/alpha :block/order "a1" :block/closed-value-property 950014}]
   (map-indexed
    (fn [index props]
      (merge {:db/id (+ 950100 index) :block/uuid (uuid-for (+ 100 index)) :block/title (str "Row " index)
              :block/page 950000 :block/parent 950000 :block/order (str "b" index)
              :block/created-at (+ 1000 index) :block/updated-at (- 2000 index) :user.property/conformance-row? true :block/tags [950006]}
             props))
    [{}
     {:user.property/text 950020 :user.property/number 950030 :user.property/many [950030 950031] :user.property/flag true :user.property/date 950040 :user.property/choice 950050 :user.property/time 1000 :user.property/raw 0}
     {:user.property/text 950021 :user.property/number 950031 :user.property/many [950032 950031] :user.property/flag false :user.property/date 950041 :user.property/choice 950051 :user.property/time 2000 :user.property/raw ""}
     {:user.property/text 950022 :user.property/number 950032 :user.property/many [950032] :user.property/raw "10"}
     {:user.property/text 950023 :user.property/number 950033 :user.property/raw "2"}
     {:user.property/text 950024 :user.property/number 950005 :user.property/many [950005] :user.property/raw :logseq.property/empty-placeholder}
     {:user.property/raw "   "}
     {:user.property/raw false}
     {:user.property/raw true}])))

(def row-ids (vec (range 950100 950109)))
(def props [:block/title :user.property/text :user.property/number :user.property/many :user.property/date :user.property/choice :user.property/time :user.property/flag :user.property/raw])
(defn filter-case [attr op match]
  {:name (str attr " " op " " (pr-str match)) :filters {:or? false :filters [[attr op match]]}})
(def cases
  (concat
   (for [attr props asc? [true false] minor? [true false]]
     {:name (str "sort " attr " " asc? " " minor?)
      :sorting (cond-> [{:id attr :asc? asc?}] minor? (conj {:id :block/title :asc? false}))})
   (for [attr props op [:is :is-not] match [nil :empty #{} #{(uuid-for 20)} #{(uuid-for 50)} true false]] (filter-case attr op match))
   (for [attr props op [:text-contains :text-not-contains] match ["apple" "APPLE" "μηλο" "" "10"]] (filter-case attr op match))
   (for [attr [:user.property/number :user.property/many :user.property/raw]
         op [:number-gt :number-gte :number-lt :number-lte] match [nil 0 -2.5 10 11 "2"]] (filter-case attr op match))
   (for [attr [:user.property/number :user.property/many :user.property/raw]
         match [[] [nil nil] [nil 0] [0 nil] [-2.5 10] [10 10] [11 0]]] (filter-case attr :between match))
   (for [op [:date-before :date-after] match [nil {:block/journal-day 20261002} {:block/journal-day 20261001}]] (filter-case :user.property/date op match))
   (for [op [:before :after] match [nil 1000 1500 2000 "invalid"]] (filter-case :user.property/time op match))
   (for [input ["" " " "ROW 1" "row 9" "ΜΗΛΟ"]] {:name (str "search " (pr-str input)) :input input})
   [{:name "unknown operator matches master" :filters {:filters [[:user.property/number :future-operator 1]]}}
    {:name "OR empty clauses" :filters {:or? true :filters []}}
    {:name "AND empty clauses" :filters {:or? false :filters []}}
    {:name "OR with search" :input "ROW 1" :filters {:or? true :filters [[:user.property/number :number-gte 0] [:user.property/text :text-contains "Orange"]]}}
    {:name "AND combination" :filters {:or? false :filters [[:user.property/number :number-gte 0] [:user.property/text :text-contains "apple"]]}}]))

(def conn (d/create-conn schema))
(def physical-data
  (mapv (fn [entity]
          (if (= :db.type/ref (get-in schema [(:db/ident entity) :db/valueType]))
            (assoc entity :db/valueType :db.type/ref
                   :db/cardinality (or (get-in schema [(:db/ident entity) :db/cardinality]) :db.cardinality/one))
            entity)) data))
(d/transact! conn physical-data)
(def scopes
  [{:feature :query-result :owner 2 :view 4 :view-id 950003 :options {:query-entity-ids row-ids}}
   {:feature :class-objects :owner 6 :view 7 :view-id 950007 :options {:view-for-id 950006}}
   {:feature :property-objects :owner 18 :view 8 :view-id 950008 :options {:view-for-id 950018}}])

(def generated
  {:masterCommit master-commit :schema (pr-str schema) :tx (pr-str physical-data) :owner (str (uuid-for 2)) :view (str (uuid-for 4))
   :cases (mapv (fn [[scope case]]
                  (let [options (merge {:view-feature-type (:feature scope)
                                        :sorting [{:id :block/title :asc? true}]} (dissoc case :name))
                        options (merge options (:options scope))
                        source-entities (if (= :query-result (:feature scope))
                                          (map #(d/entity @conn %) (set row-ids))
                                          (view/get-view-entities @conn (:view-id scope) options))
                        base {:name (str (:feature scope) " " (:name case))
                              :feature (name (:feature scope)) :owner (str (uuid-for (:owner scope))) :view (str (uuid-for (:view scope)))
                              :sorting (pr-str (:sorting options)) :filters (pr-str (:filters options)) :input (or (:input options) "")
                              :sourceRows (mapv #(str (:block/uuid %)) source-entities)}]
                    (try
                      (assoc base :rows (mapv #(str (:block/uuid (d/entity @conn %))) (:data (view/get-view-data @conn (:view-id scope) options))))
                      (catch :default error (assoc base :error true :errorMessage (.-message error))))))
                (for [scope scopes case cases] [scope case]))})
(defn -main [output]
  (when-let [failed (first (filter :error (:cases generated)))]
    (throw (ex-info "Master rejected a valid conformance fixture" failed)))
  (fs/writeFileSync output (js/JSON.stringify (clj->js generated) nil 2))
  (println "Generated" (count (:cases generated)) "master view cases at" master-commit))

(set! *main-cli-fn* -main)
