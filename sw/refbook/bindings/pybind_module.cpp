#include <refbook/book.h>
#include <refbook/book_event.h>
#include <refbook/tob_delta.h>

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>
#include <pybind11/numpy.h>

namespace py = pybind11;

PYBIND11_MODULE(refbook, m) {
  m.doc() = "Nanobook reference book (golden model) — Python bindings";

  py::enum_<refbook::EventType>(m, "EventType")
      .value("Add",    refbook::EventType::Add)
      .value("Cancel", refbook::EventType::Cancel)
      .value("Delete", refbook::EventType::Delete)
      .value("Exec",   refbook::EventType::Exec)
      .value("ExecPx", refbook::EventType::ExecPx);

  py::class_<refbook::BookEvent>(m, "BookEvent")
      .def(py::init<>())
      .def_readwrite("type",       &refbook::BookEvent::type)
      .def_readwrite("side",       &refbook::BookEvent::side)
      .def_readwrite("symbol_id",  &refbook::BookEvent::symbol_id)
      .def_readwrite("price",      &refbook::BookEvent::price)
      .def_readwrite("shares",     &refbook::BookEvent::shares)
      .def_readwrite("order_id",   &refbook::BookEvent::order_id)
      .def_readwrite("ingress_ts", &refbook::BookEvent::ingress_ts);

  py::class_<refbook::TobDelta>(m, "TobDelta")
      .def_readonly("ingress_ts",     &refbook::TobDelta::ingress_ts)
      .def_readonly("emit_ts",        &refbook::TobDelta::emit_ts)
      .def_readonly("symbol_id",      &refbook::TobDelta::symbol_id)
      .def_readonly("side",           &refbook::TobDelta::side)
      .def_readonly("reason",         &refbook::TobDelta::reason)
      .def_readonly("new_best_price", &refbook::TobDelta::new_best_price)
      .def_readonly("new_best_size",  &refbook::TobDelta::new_best_size)
      .def_readonly("flags",          &refbook::TobDelta::flags);

  py::class_<refbook::BookStats>(m, "BookStats")
      .def_readonly("events_in",     &refbook::BookStats::events_in)
      .def_readonly("deltas_out",    &refbook::BookStats::deltas_out)
      .def_readonly("rebases",       &refbook::BookStats::rebases)
      .def_readonly("hash_inserts",  &refbook::BookStats::hash_inserts)
      .def_readonly("hash_lookups",  &refbook::BookStats::hash_lookups)
      .def_readonly("hash_missed",   &refbook::BookStats::hash_missed)
      .def_readonly("duplicate_add", &refbook::BookStats::duplicate_add);

  py::class_<refbook::Book>(m, "Book")
      .def(py::init<uint16_t, std::size_t, uint32_t>(),
           py::arg("n_symbols") = 100,
           py::arg("pool_capacity") = 1'000'000,
           py::arg("initial_midprice") = 1'000'000)
      .def("step",     &refbook::Book::step)
      .def("reset",    &refbook::Book::reset)
      .def("snapshot", &refbook::Book::snapshot)
      .def("stats",    &refbook::Book::stats);
}
