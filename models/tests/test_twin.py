# SPDX-License-Identifier: Apache-2.0
"""One day of the digital twin.

The tick decides who gets infected, and a participant is told the result. Every test here is a way
the answer could be wrong without looking wrong: a tick that is not reproducible, protection that
does not protect, or a recovery clock that restarts and makes infection permanent.
"""

from __future__ import annotations

import copy

import pytest

from starsim_epidemica.twin import edge_weight, tick


def agent(
    index,
    state="susceptible",
    *,
    subject=None,
    virtual=False,
    protected=None,
    protection=None,
    **clocks,
):
    """One agent.

    `protection` is the fraction of the day it was protected for; `protected` writes the older
    boolean instead, so the compatibility path stays exercised rather than merely claimed.
    """
    record = {
        "index": index,
        "subject": subject or (None if virtual else f"subject-{index:04d}"),
        "virtual": virtual,
        "state": state,
    }
    if protected is not None:
        record["protected"] = protected
    else:
        record["protection"] = 0.0 if protection is None else protection
    record.update(clocks)
    return record


def sick(index, *, infected_on_day=0, recovers_on_day=None, **kwargs):
    """An agent already infected when the day starts, with its recovery clock still running."""
    clocks = {"infected_on_day": infected_on_day}
    if recovers_on_day is not None:
        clocks["recovers_on_day"] = recovers_on_day
    return agent(index, "infected", **clocks, **kwargs)


def document(agents, contacts=(), *, day=1, seed=42, beta=0.9, total_cases_before=0, mixing=None):
    pars = {"diseases": {"type": "sir", "beta": beta, "init_prev": 0}}
    if mixing is not None:
        pars["virtual"] = mixing
    return {
        "study_id": "c0badf00-1111-4222-8333-444455556666",
        "day": day,
        "seed": seed,
        "population": len(agents),
        "pars": pars,
        "protection": {"efficacy": 1.0, "blocks_transmission": True},
        "agents": list(agents),
        "contacts": list(contacts),
        "total_cases_before": total_cases_before,
    }


def contact(a, b, seconds=3600.0, band="immediate"):
    bands = {"immediate": 0.0, "close": 0.0, "medium": 0.0, "far": 0.0}
    bands[band] = seconds
    return {"a": a, "b": b, "seconds": seconds, "band_seconds": bands}


def states(result):
    return {a["index"]: a["state"] for a in result["agents"]}


class TestReproducibility:
    def test_the_same_document_always_gives_the_same_answer(self):
        doc = document(
            [sick(0)] + [agent(i) for i in range(1, 12)],
            [contact(0, i) for i in range(1, 12)],
        )

        first = tick(copy.deepcopy(doc))
        second = tick(copy.deepcopy(doc))

        # A participant is told this result. Re-running a stored tick has to be a verification,
        # not a fresh roll of the dice.
        assert first == second

    def test_a_different_seed_can_give_a_different_answer(self):
        agents = [sick(0)] + [agent(i) for i in range(1, 30)]
        edges = [contact(0, i, seconds=600.0) for i in range(1, 30)]

        results = {
            tuple(sorted(states(tick(document(agents, edges, seed=s))).items()))
            for s in range(8)
        }

        # Otherwise the seed is not actually driving anything and "deterministic" is vacuous.
        assert len(results) > 1

    def test_the_input_document_is_not_mutated(self):
        doc = document([sick(0), agent(1)], [contact(0, 1)])
        before = copy.deepcopy(doc)

        tick(doc)

        assert doc == before


class TestTransmission:
    def test_contact_with_an_infected_agent_can_infect(self):
        result = tick(
            document(
                [sick(0)] + [agent(i) for i in range(1, 40)],
                [contact(0, i) for i in range(1, 40)],
                beta=0.95,
            )
        )

        assert result["newly_infected"] > 0

    def test_no_contact_means_no_transmission(self):
        result = tick(
            document([sick(0)] + [agent(i) for i in range(1, 20)], [])
        )

        assert result["newly_infected"] == 0
        assert states(result)[1] == "susceptible"

    def test_distance_matters_as_much_as_duration(self):
        # An hour across the room is not an hour at arm's length; the weighting is what carries
        # that, and a model fed only durations would treat them identically.
        assert edge_weight({"immediate": 900}) == pytest.approx(1.0)
        assert edge_weight({"far": 900}) < edge_weight({"immediate": 900})
        assert edge_weight({"immediate": 1800}) > edge_weight({"immediate": 900})


class TestProtection:
    def test_a_protected_agent_is_not_infected(self):
        result = tick(
            document(
                [sick(0)]
                + [agent(i, protected=True) for i in range(1, 40)],
                [contact(0, i) for i in range(1, 40)],
                beta=0.99,
            )
        )

        assert result["newly_infected"] == 0

    def test_a_protected_infected_agent_does_not_infect_others(self):
        # Protection is partly altruistic: this is the property that makes the choice worth
        # teaching, and the one a susceptibility-only implementation would silently lose.
        result = tick(
            document(
                [sick(0, protected=True)]
                + [agent(i) for i in range(1, 40)],
                [contact(0, i) for i in range(1, 40)],
                beta=0.99,
            )
        )

        assert result["newly_infected"] == 0

    def test_partial_efficacy_is_between_the_two(self):
        agents = [sick(0)] + [agent(i, protected=True) for i in range(1, 60)]
        edges = [contact(0, i) for i in range(1, 60)]

        doc = document(agents, edges, beta=0.99)
        doc["protection"] = {"efficacy": 0.0, "blocks_transmission": True}

        # Efficacy zero is protection in name only, and must behave exactly like no protection.
        assert tick(doc)["newly_infected"] > 0

    def test_a_full_days_protection_is_the_same_as_the_old_flag(self):
        def infected(protection_kwargs):
            return tick(
                document(
                    [sick(0)] + [agent(i, **protection_kwargs) for i in range(1, 40)],
                    [contact(0, i) for i in range(1, 40)],
                    beta=0.99,
                )
            )["newly_infected"]

        assert infected({"protection": 1.0}) == infected({"protected": True}) == 0

    def test_a_tick_stored_before_protection_was_fractional_still_runs(self):
        # A stored tick is re-run to verify it. If the engine stopped understanding the boolean,
        # every tick written before this change would become unverifiable -- which is the same as
        # not having stored it.
        legacy = tick(
            document(
                [sick(0)] + [agent(i, protected=True) for i in range(1, 40)],
                [contact(0, i) for i in range(1, 40)],
                beta=0.99,
            )
        )

        assert legacy["newly_infected"] == 0

    def test_half_a_day_protects_less_than_a_whole_one(self):
        def infected(level):
            return tick(
                document(
                    [sick(0)] + [agent(i, protection=level) for i in range(1, 120)],
                    [contact(0, i) for i in range(1, 120)],
                    beta=0.5,
                )
            )["newly_infected"]

        none, half, whole = infected(0.0), infected(0.5), infected(1.0)

        # Protecting for part of a day has to land between the two, or a participant who protected
        # at noon is either getting a whole day of immunity for free or nothing for their point.
        assert whole == 0
        assert 0 < half < none

    def test_an_absent_level_is_no_protection(self):
        result = tick(
            document(
                [sick(0)] + [{k: v for k, v in agent(i).items() if k != "protection"}
                             for i in range(1, 40)],
                [contact(0, i) for i in range(1, 40)],
                beta=0.99,
            )
        )

        assert result["newly_infected"] > 0


class TestStateContinuity:
    def test_an_infected_agent_stays_infected_across_a_quiet_day(self):
        result = tick(document([sick(0), agent(1)], []))

        assert states(result)[0] == "infected"

    def test_the_recovery_clock_carries_over_rather_than_restarting(self):
        # The recovery deadline has to be carried, not just the state. Restore an agent as
        # infected without it and the clock never expires: infection becomes permanent, which
        # looks like a plausible epidemic right up until nobody has recovered by day thirty.
        result = tick(
            document([sick(0, infected_on_day=-30, recovers_on_day=2), agent(1)], [], day=8)
        )

        assert states(result)[0] == "recovered"

    def test_a_recovery_deadline_survives_the_round_trip(self):
        # Starsim stores these as offsets into the sim's own timeline and every tick builds a
        # fresh one, so a deadline that is not translated to an absolute day gets silently
        # reinterpreted as "n days from today", every day, for ever.
        result = tick(document([sick(0, infected_on_day=0, recovers_on_day=9), agent(1)], [], day=3))

        assert result["agents"][0]["recovers_on_day"] == 9
        assert result["agents"][0]["infected_on_day"] == 0

    def test_a_recovered_agent_is_not_reinfected(self):
        result = tick(
            document(
                [sick(0)] + [agent(i, "recovered") for i in range(1, 30)],
                [contact(0, i) for i in range(1, 30)],
                beta=0.99,
            )
        )

        assert all(s == "recovered" for i, s in states(result).items() if i > 0)


class TestVirtualParticipants:
    def test_a_virtual_agent_can_infect_a_real_one(self):
        # Twenty real players produce no epidemic on their own. This is why the population is
        # completed, and why the study has to disclose that it is.
        result = tick(
            document(
                [sick(0, virtual=True)]
                + [agent(i) for i in range(1, 40)],
                [contact(0, i) for i in range(1, 40)],
                beta=0.95,
            )
        )

        assert result["newly_infected"] > 0

    def test_virtual_agents_are_reported_as_virtual(self):
        result = tick(document([agent(0, virtual=True), agent(1)], []))

        by_index = {a["index"]: a for a in result["agents"]}
        assert by_index[0]["virtual"] is True
        assert by_index[0]["subject"] is None
        assert by_index[1]["virtual"] is False


class TestUnits:
    """Time units, pinned.

    Starsim's own defaults are scaled in years and an inherited default is indistinguishable by
    inspection from an explicit day-scaled value -- they print the same repr. Both mistakes leave a
    simulation that still runs and still looks epidemic-shaped, so they need pinning by behaviour.
    """

    def test_the_infectious_period_is_measured_in_days_not_years(self):
        result = tick(document([sick(0), agent(1)], [], day=1))

        recovers = result["agents"][0]["recovers_on_day"]
        # Roughly a week. Inheriting the year-scaled default puts this beyond day 2000, so the
        # epidemic freezes with everyone permanently infected.
        assert 1 <= recovers <= 30

    def test_the_study_sets_the_infectious_period(self):
        doc = document([sick(0), agent(1)], [], day=1)
        doc["pars"]["diseases"]["dur_inf_days"] = 100
        doc["pars"]["diseases"]["dur_inf_std_days"] = 0.5

        assert tick(doc)["agents"][0]["recovers_on_day"] > 60

    def test_beta_is_per_day_not_per_year(self):
        # A per-year reading divides by 365, so a beta of 0.9 across 39 close contacts would
        # infect nobody most days and the model would look merely unlucky.
        result = tick(
            document([sick(0)] + [agent(i) for i in range(1, 40)],
                     [contact(0, i) for i in range(1, 40)], beta=0.9)
        )

        assert result["newly_infected"] > 5


class TestVirtualMixing:
    """The simulated remainder of the population has to actually mix.

    A study of twenty players on a seven-day protocol will not produce an epidemic by itself. The
    virtual population is what makes the game playable, so its contacts are part of the model and
    not a detail -- and they are also the only route by which the wider outbreak reaches anyone.
    """

    def test_virtual_agents_are_inert_without_mixing(self):
        result = tick(
            document([sick(0, virtual=True)] + [agent(i) for i in range(1, 30)], [])
        )

        assert result["newly_infected"] == 0

    def test_mixing_lets_the_virtual_population_seed_the_real_one(self):
        result = tick(
            document(
                [sick(0, virtual=True)] + [agent(i) for i in range(1, 30)],
                [],
                mixing={"contacts_per_day": 10, "band_seconds": {"immediate": 3600}},
            )
        )

        assert result["newly_infected"] > 0

    def test_mixing_is_reproducible(self):
        doc = document(
            [sick(0, virtual=True)] + [agent(i) for i in range(1, 30)],
            [],
            mixing={"contacts_per_day": 8, "band_seconds": {"immediate": 3600}},
        )

        assert tick(copy.deepcopy(doc)) == tick(copy.deepcopy(doc))

    def test_an_agent_is_never_its_own_contact(self):
        # A self-edge would let an agent reinfect itself and inflate the epidemic from nowhere.
        result = tick(
            document(
                [sick(0, virtual=True)] + [agent(i, virtual=True) for i in range(1, 20)],
                [],
                mixing={"contacts_per_day": 19, "band_seconds": {"immediate": 3600}},
            )
        )

        for record in result["agents"]:
            sources = [s["index"] for s in record.get("infection", {}).get("sources", [])]
            assert record["index"] not in sources


class TestInfectionCause:
    """Every infection records how it happened.

    A participant told they were infected is owed an account of why, and a study that cannot
    separate infections caught from real measured contact from those injected by the simulated
    population cannot report its own results honestly.
    """

    def test_a_measured_contact_is_recorded_as_such(self):
        result = tick(
            document([sick(0), agent(1)], [contact(0, 1)], beta=0.99)
        )

        infection = result["agents"][1]["infection"]
        assert infection["cause"] == "measured_contact"
        assert [s["subject"] for s in infection["sources"]] == ["subject-0000"]

    def test_a_virtual_source_is_distinguished_from_a_real_one(self):
        result = tick(
            document([sick(0, virtual=True), agent(1)], [contact(0, 1)], beta=0.99)
        )

        infection = result["agents"][1]["infection"]
        assert infection["cause"] == "virtual_population"
        assert infection["sources"][0]["virtual"] is True

    def test_several_possible_sources_are_reported_as_ambiguous(self):
        # Starsim exposes no transmission tree, so with a real and a virtual source both present
        # the honest answer is that we do not know which -- not a plausible-looking guess.
        result = tick(
            document(
                [sick(0), sick(1, virtual=True), agent(2)],
                [contact(0, 2), contact(1, 2)],
                beta=0.99,
            )
        )

        infection = result["agents"][2]["infection"]
        assert infection["cause"] == "ambiguous"
        assert len(infection["sources"]) == 2

    def test_agents_that_were_not_infected_carry_no_cause(self):
        result = tick(document([sick(0), agent(1)], []))

        assert "infection" not in result["agents"][1]
        assert "infection" not in result["agents"][0]


class TestChainedDays:
    """The production loop: yesterday's output is today's input.

    Each tick in isolation can be correct while the sequence is still wrong, because everything
    that makes a study meaningful -- an epidemic that grows and then burns out -- only exists
    across days.
    """

    def carry_over(self, result, protected=()):
        return [
            {
                "index": a["index"],
                "subject": a["subject"],
                "virtual": a["virtual"],
                "state": a["state"],
                "protection": 1.0 if a["index"] in protected else 0.0,
                "infected_on_day": a["infected_on_day"],
                "recovers_on_day": a["recovers_on_day"],
                "dies_on_day": a["dies_on_day"],
            }
            for a in result["agents"]
        ]

    def run_days(self, agents, edges, days, *, protected=(), beta=0.4):
        history = []
        total = 0
        # Protection applies from the first day, not the second. Carrying it over only between
        # ticks would leave day one unshielded, which with a dense network is the whole epidemic.
        agents = [{**a, "protection": 1.0 if a["index"] in protected else 0.0} for a in agents]
        for day in range(1, days + 1):
            result = tick(
                document(agents, edges, day=day, seed=1000 + day, beta=beta, total_cases_before=total)
            )
            history.append(result)
            total = result["total_cases"]
            agents = self.carry_over(result, protected=protected)
        return history

    def test_an_epidemic_grows_and_then_burns_out(self):
        agents = [sick(0)] + [agent(i) for i in range(1, 60)]
        edges = [
            contact(a, b, seconds=1800.0)
            for a in range(60)
            for b in range(a + 1, 60)
            if (a + b) % 3 == 0
        ]

        history = self.run_days(agents, edges, 30)
        final = history[-1]

        # It has to actually spread...
        assert final["total_cases"] > 10
        # ...and it has to end, rather than everyone staying infected for ever.
        assert sum(1 for a in final["agents"] if a["state"] == "recovered") > 5

    def test_cumulative_cases_never_decrease(self):
        agents = [sick(0)] + [agent(i) for i in range(1, 40)]
        edges = [contact(0, i, seconds=900.0) for i in range(1, 40)]

        totals = [r["total_cases"] for r in self.run_days(agents, edges, 12)]

        assert totals == sorted(totals)

    def test_a_protected_population_stays_healthy(self):
        # The counterfactual the game is teaching. If protection does not visibly change the
        # outcome over a fortnight, the choice it asks participants to make is theatre.
        agents = [sick(0)] + [agent(i) for i in range(1, 40)]
        edges = [contact(0, i, seconds=3600.0) for i in range(1, 40)]
        everyone_else = tuple(range(1, 40))

        exposed = self.run_days(agents, edges, 14)[-1]["total_cases"]
        shielded = self.run_days(agents, edges, 14, protected=everyone_else)[-1]["total_cases"]

        assert shielded < exposed

    def test_a_replayed_sequence_reproduces_the_stored_history(self):
        # This is the property the server leans on to verify a study after the fact: replay the
        # same inputs and seeds, get the same history back, agent for agent.
        agents = [sick(0)] + [agent(i) for i in range(1, 30)]
        edges = [contact(0, i, seconds=1800.0) for i in range(1, 30)]

        first = self.run_days(copy.deepcopy(agents), edges, 10)
        second = self.run_days(copy.deepcopy(agents), edges, 10)

        assert first == second


class TestAccounting:
    def test_cumulative_cases_accumulate_across_ticks(self):
        result = tick(
            document(
                [sick(0)] + [agent(i) for i in range(1, 30)],
                [contact(0, i) for i in range(1, 30)],
                beta=0.95,
                total_cases_before=4,
            )
        )

        assert result["total_cases"] == 4 + result["newly_infected"]

    def test_the_engine_version_is_recorded(self):
        result = tick(document([agent(0), agent(1)], []))

        # Pinned in the output rather than assumed, so a Starsim upgrade mid-study is visible in
        # the data rather than inferred from a deployment log.
        assert result["engine"] == "starsim"
        assert result["engine_version"]

    def test_a_population_mismatch_is_refused(self):
        doc = document([agent(0), agent(1)])
        doc["population"] = 5

        with pytest.raises(ValueError, match="expected 5 agents"):
            tick(doc)
